-- Keyholders: giving and taking keys, removing roommates, moving out, and
-- who can ring the home. Never zero Keyholders while anyone lives there.

\set dave  '00000000-0000-0000-0000-0000000000d1'
\set erin  '00000000-0000-0000-0000-0000000000e1'
\set frank '00000000-0000-0000-0000-0000000000f1'

insert into auth.users (id, raw_user_meta_data) values
  (:'dave',  '{"display_name":"Dave"}'),
  (:'erin',  '{"display_name":"Erin"}'),
  (:'frank', '{"display_name":"Frank"}');

set role authenticated;

-- Dave creates Fort Snack and invites Erin and Frank.
select set_config('request.jwt.claims', json_build_object('sub', :'dave')::text, false);
do $$
declare a public.apartments;
begin
  a := public.create_apartment('fortsnack', 'Fort Snack', 41.88, -87.63, p_city => 'Chicago');
  assert a.who_can_ring = 'neighbors', 'homes start neighbors-only';
  assert public.is_keyholder(a.id), 'the creator holds keys';
  perform set_config('test.apt', a.id::text, false);
  perform set_config('test.invite', (public.create_invite(a.id)).code, false);
end $$;

select set_config('request.jwt.claims', json_build_object('sub', :'erin')::text, false);
select public.accept_invite(current_setting('test.invite'));
select set_config('request.jwt.claims', json_build_object('sub', :'frank')::text, false);
select public.accept_invite(current_setting('test.invite'));

-- Erin has no keys yet, so she can't hand them out or change who can ring.
select set_config('request.jwt.claims', json_build_object('sub', :'erin')::text, false);
do $$
declare apt uuid := current_setting('test.apt')::uuid;
begin
  assert not public.is_keyholder(apt);
  begin
    perform public.set_keyholder(apt, '00000000-0000-0000-0000-0000000000e1', true);
    raise exception 'expected keyholder check';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.set_who_can_ring(apt, 'anyone');
    raise exception 'expected keyholder check';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.memberships set role = 'keyholder' where user_id = auth.uid();
    raise exception 'expected role to be read-only';
  exception when insufficient_privilege then null;
  end;
end $$;

-- Dave gives Erin keys, then hands his own back.
select set_config('request.jwt.claims', json_build_object('sub', :'dave')::text, false);
do $$
declare apt uuid := current_setting('test.apt')::uuid; m public.memberships;
begin
  m := public.set_keyholder(apt, '00000000-0000-0000-0000-0000000000e1', true);
  assert m.role = 'keyholder';
  assert (select role from public.apartment_roster(apt) where display_name = 'Erin') = 'keyholder',
    'roster shows who holds keys';
  m := public.set_keyholder(apt, auth.uid(), false);
  assert m.role = 'member' and not public.is_keyholder(apt);

  begin
    delete from public.memberships where user_id = auth.uid();
    raise exception 'expected direct delete to be refused';
  exception when insufficient_privilege then null;
  end;
end $$;

-- Erin is now the only Keyholder: she can't give hers back, but can remove Frank.
select set_config('request.jwt.claims', json_build_object('sub', :'erin')::text, false);
do $$
declare apt uuid := current_setting('test.apt')::uuid; a public.apartments;
begin
  begin
    perform public.set_keyholder(apt, auth.uid(), false);
    raise exception 'expected last-Keyholder check';
  exception when check_violation then null;
  end;
  assert public.is_keyholder(apt), 'failed hand-back changed nothing';

  begin
    perform public.remove_roommate(apt, auth.uid());
    raise exception 'expected leave_apartment hint';
  exception when invalid_parameter_value then null;
  end;

  perform public.remove_roommate(apt, '00000000-0000-0000-0000-0000000000f1');
  assert (select count(*) from public.apartment_roster(apt)) = 2;

  a := public.set_who_can_ring(apt, 'anyone');
  assert a.who_can_ring = 'anyone';

  -- Erin moves out: the keys pass to Dave, the longest-standing roommate.
  perform public.leave_apartment(apt);
  assert (select count(*) from public.apartment_roster(apt)) = 1;
  assert (select role from public.apartment_roster(apt) where display_name = 'Dave') = 'keyholder',
    'keys pass on when the last Keyholder leaves';

  begin
    perform public.leave_apartment(apt);
    raise exception 'expected not-a-roommate';
  exception when no_data_found then null;
  end;
end $$;

reset role;
