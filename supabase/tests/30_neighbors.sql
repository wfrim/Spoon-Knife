-- Neighbors: contact matching (keyed hash, both directions), removal that
-- sticks, requests, favorites cap, blocking, and the can-call rules.

\set gina  '00000000-0000-0000-0000-0000000000a1'
\set hugo  '00000000-0000-0000-0000-0000000000a2'
\set ivy   '00000000-0000-0000-0000-0000000000a3'
\set jay   '00000000-0000-0000-0000-0000000000a4'

-- Verified numbers come from phone sign-in (auth.users.phone).
insert into auth.users (id, phone, raw_user_meta_data) values
  (:'gina', '14155550101', '{"display_name":"Gina"}'),
  (:'hugo', '14155550102', '{"display_name":"Hugo"}'),
  (:'ivy',  '14155550103', '{"display_name":"Ivy"}'),
  (:'jay',  '14155550104', '{"display_name":"Jay"}');

do $$ begin
  assert (select count(*) from public.users where phone_hash is not null and display_name in ('Gina','Hugo','Ivy','Jay')) = 4,
    'verified numbers are hashed on sign-in';
  assert (select phone_hash from public.users where display_name = 'Gina')
       = private.hash_phone('(415) 555-0101'), 'formatting and a missing +1 normalize to the same hash';
  assert (select phone_hash from public.users where display_name = 'Gina')
      <> extensions.digest('14155550101', 'sha256'), 'hash is keyed, not a plain sha256';
end $$;

set role authenticated;

-- Each person makes a home: Gina → Casa Noodle, Hugo → Fort Snack, Ivy → Pine St, Jay → Greenhouse.
select set_config('request.jwt.claims', json_build_object('sub', :'gina')::text, false);
select set_config('test.casa', (public.create_apartment('casanoodle', 'Casa Noodle', 40.7, -74.0, p_city => 'New York')).id::text, false);
select set_config('request.jwt.claims', json_build_object('sub', :'hugo')::text, false);
select set_config('test.fort', (public.create_apartment('fortsnack2', 'Fort Snack', 41.9, -87.6, p_city => 'Chicago')).id::text, false);
select set_config('request.jwt.claims', json_build_object('sub', :'ivy')::text, false);
select set_config('test.pine', (public.create_apartment('pinestpalace', 'Pine St Palace', 45.5, -122.7, p_city => 'Portland')).id::text, false);
select set_config('request.jwt.claims', json_build_object('sub', :'jay')::text, false);
select set_config('test.green', (public.create_apartment('greenhouse', 'The Greenhouse', 37.8, -122.3, p_city => 'Oakland')).id::text, false);

-- Gina syncs contacts with Hugo's number in it. Only Gina has the contact,
-- but the link counts both ways.
select set_config('request.jwt.claims', json_build_object('sub', :'gina')::text, false);
do $$
declare casa uuid := current_setting('test.casa')::uuid; fort uuid := current_setting('test.fort')::uuid;
begin
  assert public.sync_contacts(array['+1 (415) 555-0102', 'not a number', '555']) = 1, 'one new neighbor';
  assert public.are_neighbors(casa, fort);
  assert (select count(*) from public.neighborhood(casa)) = 1;
  assert (select city from public.neighborhood(casa)) = 'Chicago', 'Neighborhood shows the city';
  begin
    perform 1 from public.contact_hashes;
    raise exception 'expected contact hashes to be unreadable';
  exception when insufficient_privilege then null;
  end;
  begin
    perform phone_hash from public.users;
    raise exception 'expected phone hashes to be unreadable';
  exception when insufficient_privilege then null;
  end;
end $$;

select set_config('request.jwt.claims', json_build_object('sub', :'hugo')::text, false);
do $$
declare casa uuid := current_setting('test.casa')::uuid; fort uuid := current_setting('test.fort')::uuid;
begin
  assert (select is_new from public.neighborhood(fort)) , 'contact-made neighbors show as NEW';
  perform public.mark_neighbors_seen(fort);
  assert not (select is_new from public.neighborhood(fort));

  -- Hugo removes Casa Noodle. A re-sync doesn't bring it back...
  perform public.remove_neighbor(fort, casa);
  assert not public.are_neighbors(fort, casa);
end $$;

select set_config('request.jwt.claims', json_build_object('sub', :'gina')::text, false);
do $$
declare casa uuid := current_setting('test.casa')::uuid; fort uuid := current_setting('test.fort')::uuid;
begin
  assert public.sync_contacts(array['4155550102']) = 0, 'removed neighbors are not re-added from contacts';
  assert not public.are_neighbors(casa, fort);
  -- ...but Casa Noodle can still ask.
  assert public.request_neighbor(casa, fort) = 'pending';
end $$;

select set_config('request.jwt.claims', json_build_object('sub', :'hugo')::text, false);
do $$
declare casa uuid := current_setting('test.casa')::uuid; fort uuid := current_setting('test.fort')::uuid;
        rid uuid;
begin
  select id into rid from public.neighbor_requests where to_home = fort and status = 'pending';
  assert rid is not null, 'the asked home sees the request';
  perform public.respond_neighbor_request(rid, true);
  assert public.are_neighbors(casa, fort), 'accepting links the homes again';
end $$;

-- Requests the other way around auto-accept; favorites cap at 3.
select set_config('request.jwt.claims', json_build_object('sub', :'ivy')::text, false);
select public.request_neighbor(current_setting('test.pine')::uuid, current_setting('test.casa')::uuid);
select set_config('request.jwt.claims', json_build_object('sub', :'jay')::text, false);
select public.request_neighbor(current_setting('test.green')::uuid, current_setting('test.casa')::uuid);

select set_config('request.jwt.claims', json_build_object('sub', :'gina')::text, false);
do $$
declare casa uuid := current_setting('test.casa')::uuid; fort uuid := current_setting('test.fort')::uuid;
        pine uuid := current_setting('test.pine')::uuid; green uuid := current_setting('test.green')::uuid;
        extra uuid;
begin
  assert public.request_neighbor(casa, pine) = 'accepted', 'asking a home that asked you accepts';
  assert public.request_neighbor(casa, green) = 'accepted';
  assert (select count(*) from public.neighborhood(casa)) = 3;

  begin
    perform public.set_favorite(casa, casa, true);
    raise exception 'expected neighbors-only check';
  exception when invalid_parameter_value then null;
  end;

  perform public.set_favorite(casa, fort, true);
  perform public.set_favorite(casa, pine, true);
  perform public.set_favorite(casa, green, true);
  perform public.set_favorite(casa, green, true);  -- idempotent, still 3
  assert (select count(*) from public.favorites) = 3;

  -- A fourth neighbor can't be favorited until one is dropped.
  extra := (public.create_apartment('gina2', 'Gina Annex', 40.7, -74.0)).id;
  perform public.request_neighbor(extra, casa);
  begin
    perform public.set_favorite(casa, extra, true);
    raise exception 'expected neighbors-only check';
  exception when invalid_parameter_value then null;
  end;
  perform public.respond_neighbor_request(
    (select id from public.neighbor_requests where from_home = extra and status = 'pending'), true);
  assert public.are_neighbors(casa, extra);
  begin
    perform public.set_favorite(casa, extra, true);
    raise exception 'expected the 3-favorite cap';
  exception when check_violation then null;
  end;
  perform public.set_favorite(casa, green, false);
  perform public.set_favorite(casa, extra, true);
  assert (select count(*) from public.favorites where home_id = casa) = 3, 'swap works once one is dropped';
  perform set_config('test.extra', extra::text, false);
end $$;

-- Who may ring Casa Noodle: neighbors by default.
reset role;
do $$
declare casa uuid := current_setting('test.casa')::uuid;
        hugo uuid := '00000000-0000-0000-0000-0000000000a2';
        stranger uuid := '00000000-0000-0000-0000-00000000000c';
begin
  assert public.can_ring_home(hugo, casa), 'a neighbor can ring';
  assert not public.can_ring_home(stranger, casa), 'a stranger (Carol, from test 10) cannot ring a neighbors-only home';
end $$;

-- Hugo's home gets blocked by Casa Noodle: link, favorite and ringing all go.
set role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'gina')::text, false);
select public.block_home(current_setting('test.casa')::uuid, current_setting('test.fort')::uuid, true);
reset role;
do $$
declare casa uuid := current_setting('test.casa')::uuid; fort uuid := current_setting('test.fort')::uuid;
        hugo uuid := '00000000-0000-0000-0000-0000000000a2';
begin
  assert not public.are_neighbors(casa, fort);
  assert not exists (select 1 from public.favorites where favorite_id = fort);
  assert not public.can_ring_home(hugo, casa), 'blocked homes cannot ring';
  update public.apartments set who_can_ring = 'anyone' where id = casa;
  assert not public.can_ring_home(hugo, casa), 'a block beats "anyone"';
end $$;

-- Asking a home that blocked you looks normal but goes nowhere.
set role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'hugo')::text, false);
do $$
declare casa uuid := current_setting('test.casa')::uuid; fort uuid := current_setting('test.fort')::uuid;
begin
  assert public.request_neighbor(fort, casa) = 'pending';
  assert not exists (select 1 from public.neighbor_requests where from_home = fort and to_home = casa and status = 'pending'),
    'no request reaches a home that blocked you';
  -- Contacts can't route around a block either.
  perform public.sync_contacts(array['4155550101']);
  assert not public.are_neighbors(casa, fort);
end $$;

-- Calling people directly: contacts by default, blocks win, roommates always.
reset role;
do $$
declare gina uuid := '00000000-0000-0000-0000-0000000000a1'; hugo uuid := '00000000-0000-0000-0000-0000000000a2';
        ivy  uuid := '00000000-0000-0000-0000-0000000000a3';
begin
  -- Gina has Hugo's number, so Hugo can call Gina; Ivy isn't in Gina's contacts.
  assert public.can_call_user(hugo, gina), 'in the target''s contacts';
  assert not public.can_call_user(ivy, gina), 'not in the target''s contacts';
  update public.users set who_can_call = 'neighbors' where id = gina;
  assert public.can_call_user(ivy, gina), 'neighbors setting lets Pine St call';
  update public.users set who_can_call = 'nobody' where id = gina;
  assert not public.can_call_user(ivy, gina);
  insert into public.user_blocks values (gina, hugo);
  update public.users set who_can_call = 'anyone' where id = gina;
  assert not public.can_call_user(hugo, gina), 'a person block beats "anyone"';
end $$;

-- Sync limits.
set role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'jay')::text, false);
do $$
begin
  for i in 1..10 loop perform public.sync_contacts(array['4155550101']); end loop;
  begin
    perform public.sync_contacts(array['4155550101']);
    raise exception 'expected daily sync limit';
  exception when program_limit_exceeded then null;
  end;
  begin
    perform public.sync_contacts(array_fill('4155550101'::text, array[5001]));
    raise exception 'expected size limit';
  exception when invalid_parameter_value then null;
  end;
end $$;

-- A phone number can't be claimed by editing your profile.
do $$ begin
  update public.users set phone = '14155550101' where id = auth.uid();
  raise exception 'expected phone to be read-only';
exception when insufficient_privilege then null;
end $$;

reset role;
