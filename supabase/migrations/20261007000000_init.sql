-- Apartment Line — initial schema.
--
-- The seven tables from docs/PLAN.md, plus invites and the two Phase 0
-- measurement tables (presence_events, presence_checks).
--
-- Presence rule: the server decides who rings (plan B1). A device's presence
-- only changes through report_presence(), which logs every report and applies
-- it if it's the newest thing we know. Presence older than presence_ttl()
-- reads as 'unknown', and an unknown phone never rings.

-- ─── Types ──────────────────────────────────────────────────────────────────

create type public.presence_state  as enum ('home', 'away', 'unknown');
create type public.presence_source as enum ('geofence', 'manual', 'heartbeat');
create type public.member_role     as enum ('keyholder', 'member');
create type public.call_state      as enum ('ringing', 'active', 'ended', 'missed');

-- ─── Tables ─────────────────────────────────────────────────────────────────

create table public.users (
  id           uuid primary key references auth.users (id) on delete cascade,
  apple_sub    text unique,
  display_name text not null default '' check (length(display_name) <= 60),
  photo_url    text,
  phone        text,                       -- opt-in, only for text-backs (B7)
  created_at   timestamptz not null default now()
);

create table public.apartments (
  id          uuid primary key default gen_random_uuid(),
  handle      text not null unique check (handle ~ '^[a-z0-9_]{3,30}$'),
  name        text not null check (length(name) between 1 and 60),
  photo_url   text,
  emoji       text check (length(emoji) <= 16),
  status_line text check (length(status_line) <= 140),
  home_lat    double precision not null check (home_lat between -90 and 90),
  home_lng    double precision not null check (home_lng between -180 and 180),
  -- 200 m default: indoor GPS drifts 30–65 m, so tighter circles miss people at home.
  radius_m    integer not null default 200 check (radius_m between 50 and 2000),
  -- Shown on the profile and in Neighborhood ("Casa Noodle · New York"). Never the address.
  city        text check (length(city) between 1 and 60),
  created_by  uuid references public.users (id) on delete set null,
  created_at  timestamptz not null default now()
);

create index apartments_name_idx on public.apartments (lower(name));

create table public.memberships (
  user_id      uuid not null references public.users (id) on delete cascade,
  apartment_id uuid not null references public.apartments (id) on delete cascade,
  role         public.member_role not null default 'member',
  ring_enabled boolean not null default true,  -- personal "don't ring me"
  joined_at    timestamptz not null default now(),
  primary key (user_id, apartment_id)
);

create index memberships_apartment_idx on public.memberships (apartment_id);

create table public.invites (
  code         text primary key default substr(replace(gen_random_uuid()::text, '-', ''), 1, 10),
  apartment_id uuid not null references public.apartments (id) on delete cascade,
  created_by   uuid not null references public.users (id) on delete cascade,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '7 days'
);

-- One row per iPhone. POC assumption: a user belongs to one home apartment,
-- so a device's presence is relative to that apartment's geofence.
create table public.devices (
  id                   uuid primary key default gen_random_uuid(),
  user_id              uuid not null default auth.uid() references public.users (id) on delete cascade,
  name                 text not null default '' check (length(name) <= 60),
  voip_token           text,
  apns_token           text,
  activity_start_token text,
  presence             public.presence_state not null default 'unknown',
  presence_source      public.presence_source,
  presence_at          timestamptz,
  created_at           timestamptz not null default now()
);

create index devices_user_idx on public.devices (user_id);

create table public.calls (
  id             uuid primary key default gen_random_uuid(),
  apartment_id   uuid references public.apartments (id) on delete cascade,
  target_user_id uuid references public.users (id) on delete cascade,  -- direct person call
  caller_id      uuid not null references public.users (id) on delete cascade,
  room_name      text not null default gen_random_uuid()::text,
  state          public.call_state not null default 'ringing',
  answered_by    uuid references public.users (id) on delete set null,
  participants   uuid[] not null default '{}',
  started_at     timestamptz not null default now(),
  ended_at       timestamptz,
  check ((apartment_id is null) <> (target_user_id is null))
);

create index calls_apartment_idx on public.calls (apartment_id, started_at desc);

create table public.messages (
  id           uuid primary key default gen_random_uuid(),
  apartment_id uuid not null references public.apartments (id) on delete cascade,
  sender_id    uuid not null default auth.uid() references public.users (id) on delete cascade,
  audio_url    text,
  duration_s   numeric(5, 1) check (duration_s between 0 and 60),
  text         text check (length(text) <= 500),
  created_at   timestamptz not null default now(),
  check (audio_url is not null or text is not null)
);

create index messages_apartment_idx on public.messages (apartment_id, created_at desc);

create table public.message_listens (
  message_id  uuid not null references public.messages (id) on delete cascade,
  user_id     uuid not null default auth.uid() references public.users (id) on delete cascade,
  listened_at timestamptz not null default now(),
  primary key (message_id, user_id)
);

-- Phase 0: every presence report, applied or not.
create table public.presence_events (
  id          bigint generated always as identity primary key,
  device_id   uuid not null references public.devices (id) on delete cascade,
  user_id     uuid not null references public.users (id) on delete cascade,
  state       public.presence_state not null,
  source      public.presence_source not null,
  reported_at timestamptz not null,           -- when the phone saw it
  received_at timestamptz not null default now(),
  applied     boolean not null,               -- false = older than current, or held by a manual override
  detail      jsonb not null default '{}'
);

create index presence_events_device_idx on public.presence_events (device_id, reported_at);

-- Phase 0: ground truth. A tester taps "I'm home / I'm away" and we snapshot
-- what the server believed at that moment (gate: >= 95% within 5 minutes).
create table public.presence_checks (
  id              bigint generated always as identity primary key,
  device_id       uuid not null references public.devices (id) on delete cascade,
  user_id         uuid not null references public.users (id) on delete cascade,
  actual          public.presence_state not null check (actual <> 'unknown'),
  recorded        public.presence_state not null,
  recorded_source public.presence_source,
  note            text check (length(note) <= 200),  -- e.g. "café downstairs"
  checked_at      timestamptz not null default now()
);

-- ─── New auth user → public profile ─────────────────────────────────────────

create function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.users (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'display_name', ''))
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

-- ─── Presence ───────────────────────────────────────────────────────────────

-- Heartbeat expiry: presence nobody has confirmed in this long reads as unknown.
-- The app re-reports its geofence state from background refresh every few hours.
create function public.presence_ttl()
returns interval
language sql
immutable
as $$ select interval '24 hours' $$;

create function public.effective_presence(p_presence public.presence_state, p_at timestamptz)
returns public.presence_state
language sql
stable
as $$
  select case
    when p_at is null or p_at < now() - public.presence_ttl() then 'unknown'::public.presence_state
    else p_presence
  end
$$;

-- POST /presence. Rules:
--   * Reports can arrive late (the phone queues them when offline), so a report
--     older than the device's current presence_at is logged but not applied.
--   * A manual override holds until the next geofence crossing: a heartbeat that
--     disagrees with it only refreshes presence_at.
create function public.report_presence(
  p_device_id   uuid,
  p_state       public.presence_state,
  p_source      public.presence_source,
  p_reported_at timestamptz default now(),
  p_detail      jsonb default '{}'
)
returns public.devices
language plpgsql
security definer
set search_path = ''
as $$
declare
  d         public.devices;
  v_at      timestamptz := least(coalesce(p_reported_at, now()), now());
  v_applied boolean := false;
begin
  if p_state is null or p_state = 'unknown' then
    raise exception 'state must be home or away' using errcode = '22023';
  end if;

  select * into d from public.devices
   where id = p_device_id and user_id = auth.uid()
   for update;
  if not found then
    raise exception 'device not found' using errcode = 'P0002';
  end if;

  if d.presence_at is not null and v_at < d.presence_at then
    null;  -- stale report
  elsif p_source = 'heartbeat' and d.presence_source = 'manual' and d.presence <> p_state then
    update public.devices set presence_at = v_at where id = d.id returning * into d;
  else
    v_applied := true;
    update public.devices
       set presence = p_state, presence_source = p_source, presence_at = v_at
     where id = d.id
    returning * into d;
  end if;

  insert into public.presence_events (device_id, user_id, state, source, reported_at, applied, detail)
  values (d.id, d.user_id, p_state, p_source, v_at, v_applied, coalesce(p_detail, '{}'));

  return d;
end;
$$;

create function public.record_presence_check(
  p_device_id uuid,
  p_actual    public.presence_state,
  p_note      text default null
)
returns public.presence_checks
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.devices;
  c public.presence_checks;
begin
  select * into d from public.devices where id = p_device_id and user_id = auth.uid();
  if not found then
    raise exception 'device not found' using errcode = 'P0002';
  end if;

  insert into public.presence_checks (device_id, user_id, actual, recorded, recorded_source, note)
  values (d.id, d.user_id, p_actual,
          public.effective_presence(d.presence, d.presence_at), d.presence_source,
          nullif(trim(p_note), ''))
  returning * into c;
  return c;
end;
$$;

-- ─── Apartments ─────────────────────────────────────────────────────────────

create function public.is_member(p_apartment_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.memberships
     where apartment_id = p_apartment_id and user_id = auth.uid()
  )
$$;

-- POST /apartments: creates the profile and makes the caller its first Keyholder.
create function public.create_apartment(
  p_handle      text,
  p_name        text,
  p_home_lat    double precision,
  p_home_lng    double precision,
  p_radius_m    integer default 200,
  p_status_line text default null,
  p_emoji       text default null,
  p_city        text default null
)
returns public.apartments
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.apartments;
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;

  insert into public.apartments (handle, name, home_lat, home_lng, radius_m, status_line, emoji, city, created_by)
  values (lower(trim(leading '@' from p_handle)), trim(p_name), p_home_lat, p_home_lng,
          coalesce(p_radius_m, 200), p_status_line, p_emoji, nullif(trim(p_city), ''), auth.uid())
  returning * into a;

  insert into public.memberships (user_id, apartment_id, role) values (auth.uid(), a.id, 'keyholder');
  return a;
end;
$$;

-- POST /apartments/:id/invites
create function public.create_invite(p_apartment_id uuid)
returns public.invites
language plpgsql
security definer
set search_path = ''
as $$
declare
  i public.invites;
begin
  if not public.is_member(p_apartment_id) then
    raise exception 'not a member of this apartment' using errcode = '42501';
  end if;
  insert into public.invites (apartment_id, created_by) values (p_apartment_id, auth.uid())
  returning * into i;
  return i;
end;
$$;

-- POST /invites/:code/accept
create function public.accept_invite(p_code text)
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

  insert into public.memberships (user_id, apartment_id) values (auth.uid(), i.apartment_id)
  on conflict (user_id, apartment_id) do nothing;

  select * into m from public.memberships where user_id = auth.uid() and apartment_id = i.apartment_id;
  return m;
end;
$$;

-- Who's home, per member — what a caller sees on the apartment profile.
-- A member is home if any of their phones is (freshly) home.
create function public.apartment_roster(p_apartment_id uuid)
returns table (
  user_id      uuid,
  display_name text,
  photo_url    text,
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
   group by u.id, u.display_name, u.photo_url
   order by u.display_name, u.id
$$;

-- ─── Calls ──────────────────────────────────────────────────────────────────

-- The phones a call to this apartment rings: members who haven't turned off
-- ringing, on devices that are freshly home and can receive VoIP pushes.
-- Server-only (the call fan-out Edge Function uses the service role).
create function public.ring_targets(p_apartment_id uuid)
returns table (user_id uuid, device_id uuid, voip_token text)
language sql
stable
security definer
set search_path = ''
as $$
  select d.user_id, d.id, d.voip_token
    from public.memberships m
    join public.devices d on d.user_id = m.user_id
   where m.apartment_id = p_apartment_id
     and m.ring_enabled
     and d.voip_token is not null
     and public.effective_presence(d.presence, d.presence_at) = 'home'
$$;

-- POST /calls/:id/answer. First answer wins: the update only matches while the
-- call is still ringing, and the row lock makes a simultaneous second answer
-- re-check that condition and match nothing. Returns no rows if you lost.
create function public.answer_call(p_call_id uuid)
returns setof public.calls
language sql
security definer
set search_path = ''
as $$
  update public.calls c
     set state = 'active',
         answered_by = auth.uid(),
         participants = array[c.caller_id, auth.uid()]
   where c.id = p_call_id
     and c.state = 'ringing'
     and auth.uid() <> c.caller_id
     and (c.target_user_id = auth.uid()
          or (c.apartment_id is not null and exists (
                select 1 from public.memberships m
                 where m.apartment_id = c.apartment_id and m.user_id = auth.uid())))
  returning c.*
$$;

-- ─── Row-level security ─────────────────────────────────────────────────────

alter table public.users           enable row level security;
alter table public.apartments      enable row level security;
alter table public.memberships     enable row level security;
alter table public.invites         enable row level security;
alter table public.devices         enable row level security;
alter table public.calls           enable row level security;
alter table public.messages        enable row level security;
alter table public.message_listens enable row level security;
alter table public.presence_events enable row level security;
alter table public.presence_checks enable row level security;

create policy users_read on public.users for select to authenticated using (true);
create policy users_update_self on public.users for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- Decision 3 (Oct 6): anyone can find and call an apartment in the POC.
create policy apartments_read on public.apartments for select to authenticated using (true);
create policy apartments_update_members on public.apartments for update to authenticated
  using (public.is_member(id)) with check (public.is_member(id));

create policy memberships_read on public.memberships for select to authenticated
  using (user_id = auth.uid() or public.is_member(apartment_id));
create policy memberships_update_self on public.memberships for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy memberships_leave on public.memberships for delete to authenticated
  using (user_id = auth.uid());

create policy invites_read on public.invites for select to authenticated
  using (public.is_member(apartment_id));

create policy devices_own on public.devices for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy calls_read on public.calls for select to authenticated
  using (caller_id = auth.uid() or target_user_id = auth.uid() or public.is_member(apartment_id));

create policy messages_read on public.messages for select to authenticated
  using (sender_id = auth.uid() or public.is_member(apartment_id));
create policy messages_send on public.messages for insert to authenticated
  with check (sender_id = auth.uid());

create policy listens_read on public.message_listens for select to authenticated
  using (exists (select 1 from public.messages msg
                  where msg.id = message_id and public.is_member(msg.apartment_id)));
create policy listens_mark on public.message_listens for insert to authenticated
  with check (user_id = auth.uid()
              and exists (select 1 from public.messages msg
                           where msg.id = message_id and public.is_member(msg.apartment_id)));

create policy presence_events_own on public.presence_events for select to authenticated
  using (user_id = auth.uid());
create policy presence_checks_own on public.presence_checks for select to authenticated
  using (user_id = auth.uid());

-- ─── Grants ─────────────────────────────────────────────────────────────────
-- Supabase grants everything to anon/authenticated by default; start from
-- nothing and open only what the app needs. Presence columns are never
-- writable directly — only through report_presence().

revoke all on all tables in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;

grant select (id, display_name, photo_url, created_at) on public.users to authenticated;
grant update (display_name, photo_url, phone)         on public.users to authenticated;

grant select on public.apartments to authenticated;
grant update (name, photo_url, emoji, status_line, home_lat, home_lng, radius_m, city)
  on public.apartments to authenticated;

grant select, delete         on public.memberships to authenticated;
grant update (ring_enabled)  on public.memberships to authenticated;

grant select on public.invites to authenticated;

grant select, delete on public.devices to authenticated;
grant insert (name, voip_token, apns_token, activity_start_token) on public.devices to authenticated;
grant update (name, voip_token, apns_token, activity_start_token) on public.devices to authenticated;

grant select on public.calls to authenticated;

grant select on public.messages to authenticated;
grant insert (apartment_id, audio_url, duration_s, text) on public.messages to authenticated;

grant select on public.message_listens to authenticated;
grant insert (message_id) on public.message_listens to authenticated;

grant select on public.presence_events to authenticated;
grant select on public.presence_checks to authenticated;

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
-- ring_targets() stays service-role only.
