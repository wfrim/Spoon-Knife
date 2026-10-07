-- Invite previews (no account needed), home themes, and the 8-person cap.

insert into auth.users (id, raw_user_meta_data)
select ('00000000-0000-0000-0000-0000000001' || lpad(g::text, 2, '0'))::uuid,
       json_build_object('display_name', 'Person ' || g)::jsonb
  from generate_series(1, 10) g;

set role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-000000000101')::text, false);
do $$
declare a public.apartments;
begin
  a := public.create_apartment('bigtable', 'Big Table', 40.7, -73.9, p_city => 'Brooklyn');
  assert a.theme = 'simple-cobalt', 'homes start on Simple';
  update public.apartments set theme = 'rotary-avocado' where id = a.id;
  begin
    update public.apartments set theme = 'neon-pink' where id = a.id;
    raise exception 'expected theme check';
  exception when check_violation then null;
  end;
  perform set_config('test.code', (public.create_invite(a.id)).code, false);
end $$;

-- Someone who isn't signed in sees what the link is for.
reset role;
set role anon;
select set_config('request.jwt.claims', '', false);
do $$
declare p record;
begin
  select * into p from public.invite_preview(current_setting('test.code'));
  assert p.home_name = 'Big Table' and p.city = 'Brooklyn' and p.theme = 'rotary-avocado';
  assert p.invited_by = 'Person 1' and p.roommates = 1 and not p.is_full;
  assert (select count(*) from public.invite_preview('nope')) = 0, 'bad codes show nothing';
  begin
    perform public.accept_invite(current_setting('test.code'));
    raise exception 'expected anon to be refused';
  exception when insufficient_privilege then null;
  end;
end $$;

-- People 2..8 join; the 9th is turned away.
reset role;
set role authenticated;
do $$
begin
  for g in 2..9 loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', '00000000-0000-0000-0000-0000000001' || lpad(g::text, 2, '0'))::text, false);
    if g <= 8 then
      perform public.accept_invite(current_setting('test.code'));
    else
      begin
        perform public.accept_invite(current_setting('test.code'));
        raise exception 'expected the 8-person cap';
      exception when check_violation then null;
      end;
    end if;
  end loop;
  -- Re-accepting when you already live there is fine even when full.
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-000000000102')::text, false);
  perform public.accept_invite(current_setting('test.code'));
  assert (select is_full from public.invite_preview(current_setting('test.code')));
end $$;

reset role;
