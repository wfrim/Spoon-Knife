-- Invite links and home themes (Oct 9).
--
-- * apartments.theme: the home's style + colors as one key, e.g. "sticker-bubblegum"
--   (same keys as the design tokens). The whole app wears it.
-- * apartments.greeting_url: the home's recorded greeting (Storage path).
-- * invite_preview(): what an invite link shows before you sign in, for the
--   link preview page and the App Clip. Callable without an account.
-- * A home holds at most 8 people.

alter table public.apartments
  add column theme text not null default 'simple-cobalt'
    check (theme ~ '^(simple|sticker|rotary)-[a-z]+$'),
  add column greeting_url text;

grant update (theme, greeting_url) on public.apartments to authenticated;

create function public.home_capacity() returns integer language sql immutable as $$ select 8 $$;

create or replace function public.accept_invite(p_code text)
returns public.memberships
language plpgsql
security definer
set search_path = ''
as $$
declare
  i public.invites;
  m public.memberships;
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;

  select * into i from public.invites where code = p_code and expires_at > now();
  if not found then
    raise exception 'invite not found or expired' using errcode = 'P0002';
  end if;

  select * into m from public.memberships where user_id = auth.uid() and apartment_id = i.apartment_id;
  if found then
    return m;  -- already lives here
  end if;

  perform 1 from public.apartments where id = i.apartment_id for update;  -- serialize the capacity check
  if (select count(*) from public.memberships where apartment_id = i.apartment_id) >= public.home_capacity() then
    raise exception 'this home is full (8 people)' using errcode = '23514';
  end if;

  insert into public.memberships (user_id, apartment_id) values (auth.uid(), i.apartment_id)
  returning * into m;
  return m;
end;
$$;

create function public.invite_preview(p_code text)
returns table (
  home_name   text,
  handle      text,
  city        text,
  theme       text,
  invited_by  text,
  roommates   integer,
  is_full     boolean,
  expires_at  timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select a.name, a.handle, a.city, a.theme, u.display_name,
         (select count(*)::integer from public.memberships m where m.apartment_id = a.id),
         (select count(*) from public.memberships m where m.apartment_id = a.id) >= public.home_capacity(),
         i.expires_at
    from public.invites i
    join public.apartments a on a.id = i.apartment_id
    left join public.users u on u.id = i.created_by
   where i.code = p_code and i.expires_at > now()
$$;

revoke all on function public.home_capacity(), public.invite_preview(text) from public, anon, authenticated;
grant execute on function public.invite_preview(text) to anon, authenticated;
grant execute on function public.accept_invite(text) to authenticated;
