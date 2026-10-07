-- Keyholders (Oct 9). A home has any number of Keyholders and never zero
-- while anyone lives there. Keyholders choose who can ring the home, give and
-- take keys, and can remove a roommate. Any roommate can accept neighbors.

create type public.ring_policy as enum ('neighbors', 'anyone', 'nobody');

alter table public.apartments
  add column who_can_ring public.ring_policy not null default 'neighbors';

create function public.is_keyholder(p_apartment_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.memberships
     where apartment_id = p_apartment_id and user_id = auth.uid() and role = 'keyholder'
  )
$$;

create function public.require_keyholder(p_apartment_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_keyholder(p_apartment_id) then
    raise exception 'only Keyholders can do that' using errcode = '42501';
  end if;
end;
$$;

-- Locks the home's memberships so two Keyholders handing back keys at the
-- same moment can't leave it with none.
create function public.lock_roster(p_apartment_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  select 1 from public.memberships where apartment_id = p_apartment_id for update
$$;

create function public.set_keyholder(p_apartment_id uuid, p_user_id uuid, p_keyholder boolean)
returns public.memberships
language plpgsql
security definer
set search_path = ''
as $$
declare
  m public.memberships;
begin
  perform public.require_keyholder(p_apartment_id);
  perform public.lock_roster(p_apartment_id);

  update public.memberships
     set role = case when p_keyholder then 'keyholder' else 'member' end::public.member_role
   where apartment_id = p_apartment_id and user_id = p_user_id
  returning * into m;
  if not found then
    raise exception 'not a roommate of this home' using errcode = 'P0002';
  end if;

  if not exists (select 1 from public.memberships
                  where apartment_id = p_apartment_id and role = 'keyholder') then
    raise exception 'a home needs at least one Keyholder' using errcode = '23514';
  end if;
  return m;
end;
$$;

create function public.remove_roommate(p_apartment_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.require_keyholder(p_apartment_id);
  if p_user_id = auth.uid() then
    raise exception 'use leave_apartment to move yourself out' using errcode = '22023';
  end if;

  delete from public.memberships where apartment_id = p_apartment_id and user_id = p_user_id;
  if not found then
    raise exception 'not a roommate of this home' using errcode = 'P0002';
  end if;
end;
$$;

-- Moving out. If the last Keyholder leaves, keys go to whoever has lived
-- there longest.
create function public.leave_apartment(p_apartment_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  perform public.lock_roster(p_apartment_id);

  delete from public.memberships where apartment_id = p_apartment_id and user_id = auth.uid();
  if not found then
    raise exception 'not a roommate of this home' using errcode = 'P0002';
  end if;

  if not exists (select 1 from public.memberships
                  where apartment_id = p_apartment_id and role = 'keyholder') then
    update public.memberships set role = 'keyholder'
     where apartment_id = p_apartment_id
       and user_id = (select user_id from public.memberships
                       where apartment_id = p_apartment_id
                       order by joined_at, user_id
                       limit 1);
  end if;
end;
$$;

-- Stored now; enforced by the call fan-out once the neighbors tables land.
create function public.set_who_can_ring(p_apartment_id uuid, p_policy public.ring_policy)
returns public.apartments
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.apartments;
begin
  perform public.require_keyholder(p_apartment_id);
  update public.apartments set who_can_ring = p_policy where id = p_apartment_id returning * into a;
  return a;
end;
$$;

-- The roster now says who holds keys.
drop function public.apartment_roster(uuid);
create function public.apartment_roster(p_apartment_id uuid)
returns table (
  user_id      uuid,
  display_name text,
  photo_url    text,
  role         public.member_role,
  presence     public.presence_state,
  presence_at  timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select u.id,
         u.display_name,
         u.photo_url,
         m.role,
         case
           when bool_or(public.effective_presence(d.presence, d.presence_at) = 'home') then 'home'
           when bool_or(public.effective_presence(d.presence, d.presence_at) = 'away') then 'away'
           else 'unknown'
         end::public.presence_state,
         max(d.presence_at)
    from public.memberships m
    join public.users u on u.id = m.user_id
    left join public.devices d on d.user_id = m.user_id
   where m.apartment_id = p_apartment_id
   group by u.id, u.display_name, u.photo_url, m.role
   order by u.display_name, u.id
$$;

-- Leaving goes through leave_apartment() so keys are never orphaned.
drop policy memberships_leave on public.memberships;
revoke delete on public.memberships from authenticated;

revoke all on function public.is_keyholder(uuid), public.require_keyholder(uuid), public.lock_roster(uuid),
  public.set_keyholder(uuid, uuid, boolean), public.remove_roommate(uuid, uuid),
  public.leave_apartment(uuid), public.set_who_can_ring(uuid, public.ring_policy),
  public.apartment_roster(uuid)
  from public, anon, authenticated;

grant execute on function public.is_keyholder(uuid)                              to authenticated;
grant execute on function public.set_keyholder(uuid, uuid, boolean)              to authenticated;
grant execute on function public.remove_roommate(uuid, uuid)                     to authenticated;
grant execute on function public.leave_apartment(uuid)                           to authenticated;
grant execute on function public.set_who_can_ring(uuid, public.ring_policy)      to authenticated;
grant execute on function public.apartment_roster(uuid)                          to authenticated;
