-- Calling: who a call rings, ringing out to voicemail, leaving a message,
-- blocked callers, direct calls, calling as your home, hanging up.

\set kim  '00000000-0000-0000-0000-0000000000b1'
\set lena '00000000-0000-0000-0000-0000000000b2'
\set mo   '00000000-0000-0000-0000-0000000000b3'
\set nora '00000000-0000-0000-0000-0000000000b4'

insert into auth.users (id, raw_user_meta_data) values
  (:'kim',  '{"display_name":"Kim"}'),
  (:'lena', '{"display_name":"Lena"}'),
  (:'mo',   '{"display_name":"Mo"}'),
  (:'nora', '{"display_name":"Nora"}');

set role authenticated;

-- Lena and Mo live at Hilltop; Kim lives at Kim's Place; they're neighbors.
select set_config('request.jwt.claims', json_build_object('sub', :'lena')::text, false);
do $$
declare a public.apartments;
begin
  a := public.create_apartment('hilltop', 'Hilltop', 47.6, -122.3, p_city => 'Seattle');
  perform set_config('test.hill', a.id::text, false);
  perform set_config('test.inv', (public.create_invite(a.id)).code, false);
end $$;
insert into public.devices (name, voip_token) values ('Lena phone', 'voip-lena');
select public.report_presence((select id from public.devices limit 1), 'away', 'geofence');

select set_config('request.jwt.claims', json_build_object('sub', :'mo')::text, false);
select public.accept_invite(current_setting('test.inv'));
insert into public.devices (name, voip_token) values ('Mo phone', 'voip-mo');
select public.report_presence((select id from public.devices limit 1), 'home', 'geofence');

select set_config('request.jwt.claims', json_build_object('sub', :'kim')::text, false);
do $$
declare a public.apartments;
begin
  a := public.create_apartment('kimsplace', 'Kim''s Place', 47.6, -122.3);
  perform set_config('test.kimhome', a.id::text, false);
  perform public.request_neighbor(a.id, current_setting('test.hill')::uuid);
end $$;
insert into public.devices (name, voip_token) values ('Kim phone', 'voip-kim');
select public.report_presence((select id from public.devices limit 1), 'home', 'geofence');

select set_config('request.jwt.claims', json_build_object('sub', :'lena')::text, false);
select public.request_neighbor(current_setting('test.hill')::uuid, current_setting('test.kimhome')::uuid);

-- ─── Kim calls Hilltop: rings Mo (home), not Lena (away) ────────────────────

select set_config('request.jwt.claims', json_build_object('sub', :'kim')::text, false);
do $$
declare c public.calls;
begin
  c := public.start_call(p_apartment_id => current_setting('test.hill')::uuid);
  assert c.state = 'ringing' and not c.silent and c.ring_until > now() + interval '25 seconds';
  perform set_config('test.call1', c.id::text, false);

  c := public.ring_out(c.id);
  assert c.state = 'ringing', 'ring_out before 30 s does nothing';
end $$;

reset role;
do $$
declare c uuid := current_setting('test.call1')::uuid;
begin
  assert (select array_agg(voip_token) from public.call_fanout(c)) = array['voip-mo'],
    'only roommates who are home ring';
  update public.calls set ring_until = now() - interval '1 second' where id = c;
end $$;

-- 30 s pass with no answer: voicemail. Kim leaves a message.
set role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'kim')::text, false);
do $$
declare c public.calls; m public.messages;
begin
  c := public.ring_out(current_setting('test.call1')::uuid);
  assert c.state = 'voicemail' and c.ended_at is null, 'home calls ring out to voicemail';
  m := public.leave_voicemail(c.id, 'voicemails/abc.m4a', 12.5);
  assert m.call_id = c.id and m.apartment_id = current_setting('test.hill')::uuid;
  assert (select state from public.calls where id = c.id) = 'ended';
  begin
    perform public.leave_voicemail(c.id, 'voicemails/again.m4a', 3);
    raise exception 'expected one message per call';
  exception when object_not_in_prerequisite_state then null;
  end;
end $$;

-- Mo can hear it; the message is Hilltop's.
select set_config('request.jwt.claims', json_build_object('sub', :'mo')::text, false);
do $$ begin
  assert (select count(*) from public.messages where call_id = current_setting('test.call1')::uuid) = 1;
end $$;

-- ─── Strangers and blocks ───────────────────────────────────────────────────

select set_config('request.jwt.claims', json_build_object('sub', :'nora')::text, false);
do $$
declare c public.calls;
begin
  begin
    perform public.start_call(p_apartment_id => current_setting('test.hill')::uuid);
    raise exception 'expected neighbors-only';
  exception when insufficient_privilege then null;
  end;
end $$;

-- Hilltop blocks Kim's Place. Kim's call "rings" silently, then is missed.
select set_config('request.jwt.claims', json_build_object('sub', :'lena')::text, false);
select public.block_home(current_setting('test.hill')::uuid, current_setting('test.kimhome')::uuid, true);

select set_config('request.jwt.claims', json_build_object('sub', :'kim')::text, false);
do $$
declare c public.calls;
begin
  c := public.start_call(p_apartment_id => current_setting('test.hill')::uuid);
  assert c.silent and c.state = 'ringing', 'a blocked caller sees a normal ringing call';
  perform set_config('test.call2', c.id::text, false);
  c := public.ring_out(c.id, p_nobody_home => true);
  assert c.state = 'missed', 'and it never reaches voicemail';
end $$;

reset role;
do $$ begin
  assert (select count(*) from public.call_fanout(current_setting('test.call2')::uuid)) = 0, 'no pushes for blocked calls';
end $$;

-- ─── Direct calls, calling as your home, hanging up ─────────────────────────

-- Mo takes calls from anyone. Lena calls Mo directly: all of Mo's phones ring
-- (home or not), and no voicemail.
set role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'mo')::text, false);
select public.set_who_can_call('anyone');
select set_config('request.jwt.claims', json_build_object('sub', :'nora')::text, false);
do $$
declare c public.calls;
begin
  c := public.start_call(p_target_user_id => '00000000-0000-0000-0000-0000000000b3');
  perform set_config('test.call3', c.id::text, false);
  begin
    perform public.start_call(p_target_user_id => '00000000-0000-0000-0000-0000000000b3',
                              p_as_home => current_setting('test.hill')::uuid);
    raise exception 'expected: can''t call as a home you don''t live in';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
do $$
declare c uuid := current_setting('test.call3')::uuid;
begin
  assert (select array_agg(voip_token) from public.call_fanout(c)) = array['voip-mo'];
  update public.calls set ring_until = now() - interval '10 seconds' where id = c;
  assert public.expire_ringing_calls() >= 1, 'cron backstop settles abandoned rings';
  assert (select state from public.calls where id = c) = 'missed', 'direct calls are missed, not voicemail';
end $$;

-- Lena unblocks and calls Kim's Place as Hilltop. Kim answers; Mo joins Lena's side.
set role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'lena')::text, false);
select public.block_home(current_setting('test.hill')::uuid, current_setting('test.kimhome')::uuid, false);
select public.request_neighbor(current_setting('test.hill')::uuid, current_setting('test.kimhome')::uuid);
select set_config('request.jwt.claims', json_build_object('sub', :'kim')::text, false);
select public.request_neighbor(current_setting('test.kimhome')::uuid, current_setting('test.hill')::uuid);

select set_config('request.jwt.claims', json_build_object('sub', :'lena')::text, false);
select set_config('test.call4', (public.start_call(p_apartment_id => current_setting('test.kimhome')::uuid,
                                                  p_as_home => current_setting('test.hill')::uuid)).id::text, false);

select set_config('request.jwt.claims', json_build_object('sub', :'mo')::text, false);
do $$ begin
  begin
    perform public.join_call(current_setting('test.call4')::uuid);
    raise exception 'expected: can''t join before it''s answered';
  exception when insufficient_privilege then null;
  end;
end $$;

select set_config('request.jwt.claims', json_build_object('sub', :'kim')::text, false);
do $$
declare c public.calls;
begin
  select * into c from public.answer_call(current_setting('test.call4')::uuid);
  assert c.state = 'active';
  assert public.call_room(c.id) = c.room_name, 'the answerer may enter the room';
end $$;

select set_config('request.jwt.claims', json_build_object('sub', :'mo')::text, false);
do $$
declare c public.calls;
begin
  c := public.join_call(current_setting('test.call4')::uuid);
  assert '00000000-0000-0000-0000-0000000000b3' = any (c.participants), 'a roommate joins the home''s side';
  assert public.call_room(c.id) is not null;
end $$;

select set_config('request.jwt.claims', json_build_object('sub', :'nora')::text, false);
do $$ begin
  assert public.call_room(current_setting('test.call4')::uuid) is null, 'outsiders get no room';
  assert (public.end_call(current_setting('test.call4')::uuid)).state = 'active', 'outsiders can''t hang up others';
end $$;

select set_config('request.jwt.claims', json_build_object('sub', :'lena')::text, false);
do $$
declare c public.calls;
begin
  c := public.end_call(current_setting('test.call4')::uuid);
  assert c.state = 'ended' and c.end_reason = 'hung_up' and c.ended_at is not null;
end $$;

reset role;
