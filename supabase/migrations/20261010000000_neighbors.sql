-- Neighbors (Oct 9): who can reach whom.
--
-- * Homes become neighbors automatically when someone in one home has someone
--   in the other in their contacts, in either direction. Otherwise one home
--   asks and the other accepts.
-- * Contact books never reach the database. Phones send numbers over TLS to
--   sync_contacts(), which stores only HMAC-SHA256(number, server secret).
--   A plain hash of a phone number is reversible (there are only ~10^10
--   numbers), a keyed one is not without the secret.
-- * Removing a neighbor sticks: contacts never re-add them, but either home
--   can still ask again.
-- * Favorites are a private, per-home list of up to 3 neighbors.
-- * Homes block homes and people block people. Blocked parties aren't told.
-- * can_ring_home() / can_call_user() are the single answer to "may this call
--   go through"; the call fan-out uses them.

create extension if not exists pgcrypto with schema extensions;

create type public.neighbor_source  as enum ('contacts', 'request');
create type public.request_status   as enum ('pending', 'accepted', 'ignored');
create type public.call_policy      as enum ('contacts', 'neighbors', 'anyone', 'nobody');

-- ─── Secrets and phone hashing ──────────────────────────────────────────────

create schema private;
revoke all on schema private from public, anon, authenticated;

create table private.settings (
  key   text primary key,
  value text not null
);
-- Replace in production: update private.settings set value = '<64 random hex>' where key = 'contact_pepper';
-- Rotating it means every phone re-syncs contacts.
insert into private.settings values ('contact_pepper', encode(extensions.gen_random_bytes(32), 'hex'));

-- E.164-ish: keep digits; a bare 10-digit number is treated as US/Canada (+1).
create function private.normalize_phone(p_phone text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
           when d is null or length(d) < 7 or length(d) > 15 then null
           when length(d) = 10 then '1' || d
           else d
         end
    from (select nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '') as d) x
$$;

create function private.hash_phone(p_phone text)
returns bytea
language sql
stable
security definer
set search_path = ''
as $$
  select extensions.hmac(n, (select value from private.settings where key = 'contact_pepper'), 'sha256')
    from (select private.normalize_phone(p_phone) as n) x
   where n is not null
$$;

-- A person's verified number (from phone OTP sign-in) as a hash. The plain
-- users.phone column stays opt-in text-back info and is not used for matching,
-- so nobody can claim someone else's number to become their contact.
alter table public.users
  add column phone_hash bytea,
  add column who_can_call public.call_policy not null default 'contacts';
create index users_phone_hash_idx on public.users (phone_hash);

create function public.sync_auth_phone()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Upsert: on sign-up this can run before handle_new_auth_user creates the row.
  insert into public.users (id, display_name, phone_hash)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'display_name', ''), private.hash_phone(new.phone))
  on conflict (id) do update set phone_hash = excluded.phone_hash;
  return new;
end;
$$;

create trigger on_auth_phone
  after insert or update of phone on auth.users
  for each row execute function public.sync_auth_phone();

-- ─── Tables ─────────────────────────────────────────────────────────────────

create table public.contact_hashes (
  user_id    uuid not null references public.users (id) on delete cascade,
  hash       bytea not null,
  primary key (user_id, hash)
);
create index contact_hashes_hash_idx on public.contact_hashes (hash);

create table public.contact_syncs (
  user_id   uuid primary key references public.users (id) on delete cascade,
  synced_at timestamptz not null default now(),
  syncs_today integer not null default 1,
  count     integer not null
);

-- One row per pair of homes, stored with home_a < home_b.
create table public.neighbors (
  home_a      uuid not null references public.apartments (id) on delete cascade,
  home_b      uuid not null references public.apartments (id) on delete cascade,
  source      public.neighbor_source not null,
  active      boolean not null default true,
  removed_by  uuid references public.apartments (id) on delete set null,
  created_at  timestamptz not null default now(),
  primary key (home_a, home_b),
  check (home_a < home_b)
);
create index neighbors_home_b_idx on public.neighbors (home_b);

create table public.neighbor_requests (
  id            uuid primary key default gen_random_uuid(),
  from_home     uuid not null references public.apartments (id) on delete cascade,
  to_home       uuid not null references public.apartments (id) on delete cascade,
  requested_by  uuid references public.users (id) on delete set null,
  status        public.request_status not null default 'pending',
  created_at    timestamptz not null default now(),
  responded_at  timestamptz,
  check (from_home <> to_home)
);
create unique index neighbor_requests_pending_idx
  on public.neighbor_requests (from_home, to_home) where status = 'pending';
create index neighbor_requests_to_idx on public.neighbor_requests (to_home, status);

create table public.favorites (
  home_id      uuid not null references public.apartments (id) on delete cascade,
  favorite_id  uuid not null references public.apartments (id) on delete cascade,
  created_at   timestamptz not null default now(),
  primary key (home_id, favorite_id)
);

create table public.home_blocks (
  home_id     uuid not null references public.apartments (id) on delete cascade,
  blocked_id  uuid not null references public.apartments (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (home_id, blocked_id)
);

create table public.user_blocks (
  user_id     uuid not null references public.users (id) on delete cascade,
  blocked_id  uuid not null references public.users (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, blocked_id)
);
create index user_blocks_blocked_idx on public.user_blocks (blocked_id);

alter table public.memberships add column neighbors_seen_at timestamptz not null default now();

-- ─── Helpers ────────────────────────────────────────────────────────────────

create function public.require_member(p_apartment_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_member(p_apartment_id) then
    raise exception 'not a roommate of this home' using errcode = '42501';
  end if;
end;
$$;

create function public.are_neighbors(p_home uuid, p_other uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.neighbors
     where home_a = least(p_home, p_other) and home_b = greatest(p_home, p_other) and active
  )
$$;

-- Creates or revives the link; a removed link is only revived by a request.
create function private.link_homes(p_home uuid, p_other uuid, p_source public.neighbor_source)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.neighbors (home_a, home_b, source)
  values (least(p_home, p_other), greatest(p_home, p_other), p_source)
  on conflict (home_a, home_b) do update
     set active = true, removed_by = null, source = excluded.source, created_at = now()
   where p_source = 'request' and not public.neighbors.active
$$;

-- Every home pair where someone in one has someone in the other in their
-- contacts (either direction), minus blocked pairs. Idempotent.
create function private.refresh_contact_neighbors(p_user_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  linked integer := 0;
  pair record;
begin
  for pair in
    with mine as (
      select m.apartment_id from public.memberships m where m.user_id = p_user_id
    ),
    knows as (
      -- people I have in my contacts
      select u.id as other_user
        from public.contact_hashes c
        join public.users u on u.phone_hash = c.hash
       where c.user_id = p_user_id and u.id <> p_user_id
      union
      -- people who have me in theirs
      select c.user_id
        from public.users me
        join public.contact_hashes c on c.hash = me.phone_hash
       where me.id = p_user_id and c.user_id <> p_user_id
    )
    select distinct mine.apartment_id as home, om.apartment_id as other
      from mine
      cross join knows
      join public.memberships om on om.user_id = knows.other_user
     where om.apartment_id <> mine.apartment_id
       and not exists (select 1 from public.home_blocks b
                        where (b.home_id = mine.apartment_id and b.blocked_id = om.apartment_id)
                           or (b.home_id = om.apartment_id and b.blocked_id = mine.apartment_id))
  loop
    if not exists (select 1 from public.neighbors
                    where home_a = least(pair.home, pair.other) and home_b = greatest(pair.home, pair.other)) then
      perform private.link_homes(pair.home, pair.other, 'contacts');
      linked := linked + 1;
    end if;
  end loop;
  return linked;
end;
$$;

-- Moving into a home brings your contact-neighbors with you.
create function public.on_membership_added()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.refresh_contact_neighbors(new.user_id);
  return new;
end;
$$;

create trigger on_membership_added
  after insert on public.memberships
  for each row execute function public.on_membership_added();

-- ─── Contacts ───────────────────────────────────────────────────────────────

-- Replaces the caller's contact hashes. Returns how many new neighbor links it made.
create function public.sync_contacts(p_phones text[])
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  last public.contact_syncs;
begin
  if me is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  if coalesce(array_length(p_phones, 1), 0) > 5000 then
    raise exception 'too many contacts in one sync (max 5000)' using errcode = '22023';
  end if;

  -- At most 10 syncs a day per person: enough for real use, too few to
  -- enumerate the number space through the matching.
  select * into last from public.contact_syncs where user_id = me for update;
  if found and last.synced_at > now() - interval '1 day' and last.syncs_today >= 10 then
    raise exception 'contact sync limit reached, try again tomorrow' using errcode = '54000';
  end if;

  delete from public.contact_hashes where user_id = me;
  insert into public.contact_hashes (user_id, hash)
  select distinct me, h from unnest(p_phones) phone, private.hash_phone(phone) h where h is not null;

  insert into public.contact_syncs (user_id, count)
  values (me, coalesce(array_length(p_phones, 1), 0))
  on conflict (user_id) do update
     set count = excluded.count,
         syncs_today = case when public.contact_syncs.synced_at > now() - interval '1 day'
                            then public.contact_syncs.syncs_today + 1 else 1 end,
         synced_at = case when public.contact_syncs.synced_at > now() - interval '1 day'
                          then public.contact_syncs.synced_at else now() end;

  return private.refresh_contact_neighbors(me);
end;
$$;

-- ─── Neighbor actions ───────────────────────────────────────────────────────

-- Any roommate can ask. Asking a home that already asked you accepts it.
-- Asking a home that blocked you looks like it worked.
create function public.request_neighbor(p_home uuid, p_other uuid)
returns public.request_status
language plpgsql
security definer
set search_path = ''
as $$
declare
  reverse_id uuid;
begin
  perform public.require_member(p_home);
  if p_home = p_other then
    raise exception 'a home can''t neighbor itself' using errcode = '22023';
  end if;
  if public.are_neighbors(p_home, p_other) then
    return 'accepted';
  end if;
  if exists (select 1 from public.home_blocks where home_id = p_other and blocked_id = p_home) then
    return 'pending';
  end if;

  select id into reverse_id from public.neighbor_requests
   where from_home = p_other and to_home = p_home and status = 'pending';
  if found then
    update public.neighbor_requests set status = 'accepted', responded_at = now() where id = reverse_id;
    perform private.link_homes(p_home, p_other, 'request');
    return 'accepted';
  end if;

  insert into public.neighbor_requests (from_home, to_home, requested_by)
  values (p_home, p_other, auth.uid())
  on conflict do nothing;
  return 'pending';
end;
$$;

-- Any roommate of the asked home can accept or ignore.
create function public.respond_neighbor_request(p_request_id uuid, p_accept boolean)
returns public.neighbor_requests
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.neighbor_requests;
begin
  select * into r from public.neighbor_requests where id = p_request_id and status = 'pending' for update;
  if not found then
    raise exception 'no such pending request' using errcode = 'P0002';
  end if;
  perform public.require_member(r.to_home);

  update public.neighbor_requests
     set status = case when p_accept then 'accepted' else 'ignored' end::public.request_status,
         responded_at = now()
   where id = r.id
  returning * into r;
  if p_accept then
    perform private.link_homes(r.from_home, r.to_home, 'request');
  end if;
  return r;
end;
$$;

create function public.remove_neighbor(p_home uuid, p_other uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.require_member(p_home);
  update public.neighbors set active = false, removed_by = p_home
   where home_a = least(p_home, p_other) and home_b = greatest(p_home, p_other);
  delete from public.favorites
   where (home_id = p_home and favorite_id = p_other) or (home_id = p_other and favorite_id = p_home);
end;
$$;

-- Favorites: up to 3, neighbors only, private to the home.
create function public.set_favorite(p_home uuid, p_other uuid, p_on boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.require_member(p_home);
  if not p_on then
    delete from public.favorites where home_id = p_home and favorite_id = p_other;
    return;
  end if;
  if not public.are_neighbors(p_home, p_other) then
    raise exception 'only neighbors can be favorites' using errcode = '22023';
  end if;
  perform 1 from public.apartments where id = p_home for update;  -- serialize the cap check
  if (select count(*) from public.favorites where home_id = p_home and favorite_id <> p_other) >= 3 then
    raise exception 'favorites hold 3 homes; unfavorite one first' using errcode = '23514';
  end if;
  insert into public.favorites (home_id, favorite_id) values (p_home, p_other) on conflict do nothing;
end;
$$;

-- Any roommate can block a home: safety shouldn't wait for a Keyholder.
create function public.block_home(p_home uuid, p_other uuid, p_on boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.require_member(p_home);
  if not p_on then
    delete from public.home_blocks where home_id = p_home and blocked_id = p_other;
    return;
  end if;
  insert into public.home_blocks (home_id, blocked_id) values (p_home, p_other) on conflict do nothing;
  update public.neighbors set active = false, removed_by = p_home
   where home_a = least(p_home, p_other) and home_b = greatest(p_home, p_other);
  delete from public.favorites
   where (home_id = p_home and favorite_id = p_other) or (home_id = p_other and favorite_id = p_home);
  update public.neighbor_requests set status = 'ignored', responded_at = now()
   where status = 'pending'
     and ((from_home = p_other and to_home = p_home) or (from_home = p_home and to_home = p_other));
end;
$$;

create function public.block_user(p_other uuid, p_on boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or auth.uid() = p_other then
    raise exception 'can''t block that person' using errcode = '22023';
  end if;
  if p_on then
    insert into public.user_blocks (user_id, blocked_id) values (auth.uid(), p_other) on conflict do nothing;
  else
    delete from public.user_blocks where user_id = auth.uid() and blocked_id = p_other;
  end if;
end;
$$;

create function public.set_who_can_call(p_policy public.call_policy)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.users set who_can_call = p_policy where id = auth.uid()
$$;

create function public.mark_neighbors_seen(p_home uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.memberships set neighbors_seen_at = now()
   where apartment_id = p_home and user_id = auth.uid()
$$;

-- ─── Who may call ───────────────────────────────────────────────────────────

create function public.can_ring_home(p_caller uuid, p_home uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  with caller_homes as (
    select apartment_id from public.memberships where user_id = p_caller
  )
  select case
    when exists (select 1 from caller_homes where apartment_id = p_home) then true
    when exists (select 1 from public.home_blocks b join caller_homes c on c.apartment_id = b.blocked_id
                  where b.home_id = p_home) then false
    else case (select who_can_ring from public.apartments where id = p_home)
           when 'anyone' then true
           when 'nobody' then false
           else exists (select 1 from caller_homes c where public.are_neighbors(p_home, c.apartment_id))
         end
  end
$$;

create function public.can_call_user(p_caller uuid, p_target uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when p_caller = p_target then false
    when exists (select 1 from public.user_blocks
                  where (user_id = p_target and blocked_id = p_caller)) then false
    -- roommates can always reach each other
    when exists (select 1 from public.memberships a join public.memberships b using (apartment_id)
                  where a.user_id = p_caller and b.user_id = p_target) then true
    else case (select who_can_call from public.users where id = p_target)
           when 'anyone' then true
           when 'nobody' then false
           when 'neighbors' then exists (
             select 1 from public.memberships a, public.memberships b
              where a.user_id = p_caller and b.user_id = p_target
                and public.are_neighbors(a.apartment_id, b.apartment_id))
           else exists (  -- 'contacts': the target has the caller's number saved
             select 1 from public.contact_hashes c join public.users u on u.phone_hash = c.hash
              where c.user_id = p_target and u.id = p_caller)
         end
  end
$$;

-- ─── Reads for the Neighborhood tab ─────────────────────────────────────────

create function public.neighborhood(p_home uuid)
returns table (
  home_id     uuid,
  name        text,
  handle      text,
  city        text,
  source      public.neighbor_source,
  is_favorite boolean,
  is_new      boolean,
  home_count  integer
)
language sql
stable
security definer
set search_path = ''
as $$
  select a.id, a.name, a.handle, a.city, n.source,
         exists (select 1 from public.favorites f where f.home_id = p_home and f.favorite_id = a.id),
         n.created_at > (select neighbors_seen_at from public.memberships
                          where apartment_id = p_home and user_id = auth.uid()),
         (select count(*)::integer from public.apartment_roster(a.id) r where r.presence = 'home')
    from public.neighbors n
    join public.apartments a on a.id = case when n.home_a = p_home then n.home_b else n.home_a end
   where (n.home_a = p_home or n.home_b = p_home) and n.active and public.is_member(p_home)
   order by a.name
$$;

-- ─── Row-level security ─────────────────────────────────────────────────────

alter table public.contact_hashes    enable row level security;
alter table public.contact_syncs     enable row level security;
alter table public.neighbors         enable row level security;
alter table public.neighbor_requests enable row level security;
alter table public.favorites         enable row level security;
alter table public.home_blocks       enable row level security;
alter table public.user_blocks       enable row level security;

-- Writes go through the functions above; clients only read.
create policy neighbors_read on public.neighbors for select to authenticated
  using ((select public.is_member(home_a)) or (select public.is_member(home_b)));
create policy neighbor_requests_read on public.neighbor_requests for select to authenticated
  using ((select public.is_member(from_home)) or (select public.is_member(to_home)));
create policy favorites_read on public.favorites for select to authenticated
  using ((select public.is_member(home_id)));
create policy home_blocks_read on public.home_blocks for select to authenticated
  using ((select public.is_member(home_id)));
create policy user_blocks_read on public.user_blocks for select to authenticated
  using (user_id = (select auth.uid()));

-- ─── Grants ─────────────────────────────────────────────────────────────────

revoke all on public.contact_hashes, public.contact_syncs from anon, authenticated;
revoke all on public.neighbors, public.neighbor_requests, public.favorites,
              public.home_blocks, public.user_blocks from anon, authenticated;
grant select on public.neighbors, public.neighbor_requests, public.favorites,
                public.home_blocks, public.user_blocks to authenticated;

-- Hashes and policies are not readable by other people.
revoke select on public.users from authenticated;
grant select (id, display_name, photo_url, created_at) on public.users to authenticated;
revoke update (phone) on public.users from authenticated;

revoke all on all functions in schema public from public, anon, authenticated;
revoke all on all functions in schema private from public, anon, authenticated;

grant execute on function public.presence_ttl()                                          to authenticated;
grant execute on function public.effective_presence(public.presence_state, timestamptz)  to authenticated;
grant execute on function public.is_member(uuid)                                         to authenticated;
grant execute on function public.report_presence(uuid, public.presence_state, public.presence_source, timestamptz, jsonb) to authenticated;
grant execute on function public.record_presence_check(uuid, public.presence_state, text) to authenticated;
grant execute on function public.create_apartment(text, text, double precision, double precision, integer, text, text, text) to authenticated;
grant execute on function public.create_invite(uuid)                                     to authenticated;
grant execute on function public.accept_invite(text)                                     to authenticated;
grant execute on function public.apartment_roster(uuid)                                  to authenticated;
grant execute on function public.answer_call(uuid)                                       to authenticated;
grant execute on function public.is_keyholder(uuid)                                      to authenticated;
grant execute on function public.set_keyholder(uuid, uuid, boolean)                      to authenticated;
grant execute on function public.remove_roommate(uuid, uuid)                             to authenticated;
grant execute on function public.leave_apartment(uuid)                                   to authenticated;
grant execute on function public.set_who_can_ring(uuid, public.ring_policy)              to authenticated;
grant execute on function public.sync_contacts(text[])                                   to authenticated;
grant execute on function public.request_neighbor(uuid, uuid)                            to authenticated;
grant execute on function public.respond_neighbor_request(uuid, boolean)                 to authenticated;
grant execute on function public.remove_neighbor(uuid, uuid)                             to authenticated;
grant execute on function public.set_favorite(uuid, uuid, boolean)                       to authenticated;
grant execute on function public.block_home(uuid, uuid, boolean)                         to authenticated;
grant execute on function public.block_user(uuid, boolean)                               to authenticated;
grant execute on function public.set_who_can_call(public.call_policy)                    to authenticated;
grant execute on function public.mark_neighbors_seen(uuid)                               to authenticated;
grant execute on function public.are_neighbors(uuid, uuid)                               to authenticated;
grant execute on function public.neighborhood(uuid)                                      to authenticated;
-- can_ring_home / can_call_user stay server-only (the call fan-out).
