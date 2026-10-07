-- Behaviour tests for presence, apartments and first-answer calls.
-- Run by scripts/test-db.sh as a superuser; each block switches role/user the
-- way PostgREST would (SET ROLE + request.jwt.claims).

\set alice '00000000-0000-0000-0000-00000000000a'
\set bob   '00000000-0000-0000-0000-00000000000b'
\set carol '00000000-0000-0000-0000-00000000000c'

insert into auth.users (id, raw_user_meta_data) values
  (:'alice', '{"display_name":"Alice"}'),
  (:'bob',   '{"display_name":"Bob"}'),
  (:'carol', '{"display_name":"Carol"}');

do $$ begin
  assert (select count(*) from public.users) = 3, 'auth trigger creates public.users rows';
  assert (select display_name from public.users where id = '00000000-0000-0000-0000-00000000000a') = 'Alice';
end $$;

-- ─── Alice registers a phone and reports presence ───────────────────────────

set role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'alice')::text, false);

insert into public.devices (name) values ('Alice iPhone');
select set_config('test.dev_a', (select id::text from public.devices), false);

do $$
declare d public.devices; dev uuid := current_setting('test.dev_a')::uuid;
begin
  d := public.report_presence(dev, 'home', 'geofence');
  assert d.presence = 'home' and d.presence_source = 'geofence', 'geofence home applies';

  -- A queued report from 10 minutes ago arrives late: logged, not applied.
  d := public.report_presence(dev, 'away', 'geofence', now() - interval '10 minutes');
  assert d.presence = 'home', 'late report does not overwrite newer presence';

  -- Future timestamps are clamped to now.
  d := public.report_presence(dev, 'home', 'heartbeat', now() + interval '1 day');
  assert d.presence_at <= now(), 'future reported_at is clamped';

  -- Manual Away holds against a disagreeing heartbeat...
  d := public.report_presence(dev, 'away', 'manual');
  d := public.report_presence(dev, 'home', 'heartbeat');
  assert d.presence = 'away' and d.presence_source = 'manual', 'heartbeat does not override manual';

  -- ...until the next real geofence crossing.
  d := public.report_presence(dev, 'home', 'geofence');
  assert d.presence = 'home' and d.presence_source = 'geofence', 'geofence crossing ends manual override';

  assert (select count(*) from public.presence_events) = 6, 'every report is logged';
  assert (select count(*) from public.presence_events where not applied) = 2, 'stale + held reports marked unapplied';

  begin
    perform public.report_presence(dev, 'unknown', 'manual');
    raise exception 'expected rejection of unknown';
  exception when invalid_parameter_value then null;
  end;
end $$;

-- Presence columns are not directly writable.
do $$ begin
  update public.devices set presence = 'away';
  raise exception 'expected permission error';
exception when insufficient_privilege then null;
end $$;

-- Ground-truth spot check snapshots what the server believed.
do $$
declare c public.presence_checks;
begin
  c := public.record_presence_check(current_setting('test.dev_a')::uuid, 'away', '  café downstairs ');
  assert c.actual = 'away' and c.recorded = 'home' and c.recorded_source = 'geofence';
  assert c.note = 'café downstairs';
end $$;

-- ─── Alice creates an apartment and invites Bob ─────────────────────────────

do $$
declare a public.apartments; i public.invites;
begin
  a := public.create_apartment('@TheBurrow', ' The Burrow ', 40.7, -74.0);
  assert a.handle = 'theburrow' and a.name = 'The Burrow' and a.radius_m = 100;
  assert (select role from public.memberships where apartment_id = a.id) = 'owner';
  i := public.create_invite(a.id);
  perform set_config('test.apt', a.id::text, false);
  perform set_config('test.invite', i.code, false);

  begin
    perform public.create_apartment('Bad Handle!', 'x', 0, 0);
    raise exception 'expected handle check';
  exception when check_violation then null;
  end;
end $$;

-- ─── Bob joins; can't touch Alice's phone ───────────────────────────────────

select set_config('request.jwt.claims', json_build_object('sub', :'bob')::text, false);

do $$
declare m public.memberships;
begin
  assert (select count(*) from public.devices) = 0, 'Bob cannot see Alice''s devices';
  assert (select count(*) from public.presence_events) = 0, 'Bob cannot see Alice''s presence log';

  begin
    perform public.report_presence(current_setting('test.dev_a')::uuid, 'away', 'manual');
    raise exception 'expected device not found';
  exception when no_data_found then null;
  end;

  begin
    perform public.create_invite(current_setting('test.apt')::uuid);
    raise exception 'expected non-member rejection';
  exception when insufficient_privilege then null;
  end;

  m := public.accept_invite(current_setting('test.invite'));
  assert m.role = 'member' and m.ring_enabled;
  m := public.accept_invite(current_setting('test.invite'));  -- idempotent
  assert (select count(*) from public.memberships where apartment_id = m.apartment_id) = 2;
end $$;

insert into public.devices (name, voip_token) values ('Bob iPhone', 'voip-bob');

-- ─── Carol (not a member) looks the apartment up ────────────────────────────

select set_config('request.jwt.claims', json_build_object('sub', :'carol')::text, false);

do $$
declare apt uuid := current_setting('test.apt')::uuid;
begin
  assert (select count(*) from public.apartments where handle = 'theburrow') = 1, 'anyone can find an apartment';
  assert (select count(*) from public.apartment_roster(apt)) = 2;
  assert (select presence from public.apartment_roster(apt) where display_name = 'Alice') = 'home';
  assert (select presence from public.apartment_roster(apt) where display_name = 'Bob') = 'unknown',
    'a phone that never reported is unknown';
  assert (select count(*) from public.apartment_roster(apt) where presence = 'home') = 1, '"1 of 2 home"';
  assert (select count(*) from public.memberships) = 0, 'non-members cannot list memberships';

  begin
    perform * from public.ring_targets(apt);
    raise exception 'expected ring_targets to be server-only';
  exception when insufficient_privilege then null;
  end;
end $$;

reset role;

-- ─── Ring targets and heartbeat expiry (server side) ────────────────────────

set role service_role;

do $$
declare apt uuid := current_setting('test.apt')::uuid;
begin
  assert (select count(*) from public.ring_targets(apt)) = 0, 'Alice is home but has no VoIP token yet';
  update public.devices set voip_token = 'voip-alice' where id = current_setting('test.dev_a')::uuid;
  assert (select voip_token from public.ring_targets(apt)) = 'voip-alice', 'only home phones ring';

  update public.memberships set ring_enabled = false where user_id = '00000000-0000-0000-0000-00000000000a';
  assert (select count(*) from public.ring_targets(apt)) = 0, '"don''t ring me" is respected';
  update public.memberships set ring_enabled = true;

  update public.devices set presence_at = now() - interval '25 hours' where id = current_setting('test.dev_a')::uuid;
  assert (select count(*) from public.ring_targets(apt)) = 0, 'stale presence does not ring';
  assert (select presence from public.apartment_roster(apt) where display_name = 'Alice') = 'unknown';
end $$;

-- Carol calls The Burrow.
with c as (
  insert into public.calls (apartment_id, caller_id)
  values (current_setting('test.apt')::uuid, '00000000-0000-0000-0000-00000000000c')
  returning id
)
select set_config('test.call', (select id::text from c), false);

reset role;
set role authenticated;

-- ─── First answer wins ──────────────────────────────────────────────────────

select set_config('request.jwt.claims', json_build_object('sub', :'carol')::text, false);
do $$ begin
  assert (select count(*) from public.answer_call(current_setting('test.call')::uuid)) = 0,
    'the caller cannot answer their own call';
end $$;

select set_config('request.jwt.claims', json_build_object('sub', :'bob')::text, false);
do $$
declare c public.calls;
begin
  select * into c from public.answer_call(current_setting('test.call')::uuid);
  assert c.state = 'active' and c.answered_by = '00000000-0000-0000-0000-00000000000b';
  assert c.participants = array['00000000-0000-0000-0000-00000000000c', '00000000-0000-0000-0000-00000000000b']::uuid[];
end $$;

select set_config('request.jwt.claims', json_build_object('sub', :'alice')::text, false);
do $$ begin
  assert (select count(*) from public.answer_call(current_setting('test.call')::uuid)) = 0,
    'second answer loses';
  assert (select answered_by from public.calls where id = current_setting('test.call')::uuid)
         = '00000000-0000-0000-0000-00000000000b';
end $$;

-- ─── Messages: anyone can leave one; members read it ────────────────────────

select set_config('request.jwt.claims', json_build_object('sub', :'carol')::text, false);
insert into public.messages (apartment_id, text) values (current_setting('test.apt')::uuid, 'Call me back!');

do $$ begin
  insert into public.messages (apartment_id, sender_id, text)
  values (current_setting('test.apt')::uuid, '00000000-0000-0000-0000-00000000000a', 'spoofed');
  raise exception 'expected sender spoofing to fail';
exception when insufficient_privilege then null;
end $$;

select set_config('request.jwt.claims', json_build_object('sub', :'bob')::text, false);
insert into public.message_listens (message_id) select id from public.messages;
do $$ begin
  assert (select count(*) from public.message_listens) = 1, 'Bob heard the message';
end $$;

reset role;
\echo '  presence, apartments, calls, messages: ok'
