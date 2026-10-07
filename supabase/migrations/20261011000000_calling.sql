-- Calling (Oct 9): placing a call, who it rings, ringing out to voicemail.
--
--   start_call()          caller, via the place-call Edge Function: checks who may call,
--                         creates the call (ringing for 30 s)
--   call_fanout()         service only: the VoIP tokens to push
--   answer_call()         first answer wins (unchanged, init migration)
--   ring_out()            caller's phone at 30 s, or expire_ringing_calls() from cron:
--                         home calls go to voicemail, direct calls are missed
--   leave_voicemail()     caller uploads the recording; the call ends
--   join_call()           a roommate joins a call placed "as the home"
--   end_call()            hang up
--
-- Blocked callers aren't told: their call "rings" with no pushes, then ends as
-- missed without reaching voicemail.

alter type public.call_state add value if not exists 'voicemail';

alter table public.calls
  add column ring_until  timestamptz not null default now() + interval '30 seconds',
  add column as_home     uuid references public.apartments (id) on delete set null,
  add column silent      boolean not null default false,
  add column end_reason  text check (end_reason in ('hung_up', 'answered_elsewhere', 'no_answer', 'voicemail_left', 'abandoned'));

create index calls_ringing_idx on public.calls (ring_until) where state = 'ringing';

alter table public.messages add column call_id uuid references public.calls (id) on delete set null;

create function public.ring_seconds() returns interval language sql immutable as $$ select interval '30 seconds' $$;

create function public.start_call(
  p_apartment_id   uuid default null,
  p_target_user_id uuid default null,
  p_as_home        uuid default null
)
returns public.calls
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  blocked boolean := false;
  c public.calls;
begin
  if me is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  if (p_apartment_id is null) = (p_target_user_id is null) then
    raise exception 'call a home or a person' using errcode = '22023';
  end if;
  if p_as_home is not null then
    perform public.require_member(p_as_home);
  end if;

  if p_apartment_id is not null then
    if not exists (select 1 from public.apartments where id = p_apartment_id) then
      raise exception 'no such home' using errcode = 'P0002';
    end if;
    blocked := exists (select 1 from public.home_blocks b
                         join public.memberships m on m.apartment_id = b.blocked_id
                        where b.home_id = p_apartment_id and m.user_id = me);
    if not blocked and not public.can_ring_home(me, p_apartment_id) then
      raise exception 'this home only takes calls from neighbors' using errcode = '42501',
        hint = 'ask_to_be_neighbors';
    end if;
  else
    blocked := exists (select 1 from public.user_blocks where user_id = p_target_user_id and blocked_id = me);
    if not blocked and not public.can_call_user(me, p_target_user_id) then
      raise exception 'this person isn''t taking calls from you' using errcode = '42501';
    end if;
  end if;

  insert into public.calls (apartment_id, target_user_id, caller_id, as_home, silent, ring_until)
  values (p_apartment_id, p_target_user_id, me, p_as_home, blocked, now() + public.ring_seconds())
  returning * into c;
  return c;
end;
$$;

-- Phones to push. Home calls ring roommates who are home (never the caller);
-- direct calls ring all of the person's phones.
create function public.call_fanout(p_call_id uuid)
returns table (user_id uuid, device_id uuid, voip_token text)
language sql
stable
security definer
set search_path = ''
as $$
  select t.user_id, t.device_id, t.voip_token
    from public.calls c
    cross join lateral public.ring_targets(c.apartment_id) t
   where c.id = p_call_id and c.apartment_id is not null and not c.silent and c.state = 'ringing'
     and t.user_id <> c.caller_id
  union all
  select d.user_id, d.id, d.voip_token
    from public.calls c
    join public.devices d on d.user_id = c.target_user_id
   where c.id = p_call_id and c.target_user_id is not null and not c.silent and c.state = 'ringing'
     and d.voip_token is not null
$$;

-- What a ringing call becomes when nobody picks up.
create function public.settle_unanswered(c public.calls)
returns public.call_state
language plpgsql
immutable
as $$
begin
  if c.apartment_id is not null and not c.silent then
    return 'voicemail';
  end if;
  return 'missed';
end;
$$;

-- The caller's phone calls this when its 30 s timer fires (or straight away
-- when the fan-out found nobody home). Idempotent.
create function public.ring_out(p_call_id uuid, p_nobody_home boolean default false)
returns public.calls
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.calls;
begin
  update public.calls
     set state = public.settle_unanswered(calls),
         end_reason = 'no_answer',
         ended_at = case when public.settle_unanswered(calls) = 'missed' then now() end
   where id = p_call_id and caller_id = auth.uid() and state = 'ringing'
     and (p_nobody_home or ring_until <= now() + interval '1 second')
  returning * into c;
  if not found then
    select * into c from public.calls where id = p_call_id and caller_id = auth.uid();
  end if;
  return c;
end;
$$;

-- Backstop for callers that went away mid-ring (cron, every few seconds).
create function public.expire_ringing_calls()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  n integer;
begin
  update public.calls
     set state = public.settle_unanswered(calls),
         end_reason = 'no_answer',
         ended_at = case when public.settle_unanswered(calls) = 'missed' then now() end
   where state = 'ringing' and ring_until < now() - interval '5 seconds';
  get diagnostics n = row_count;
  -- A caller who never recorded anything: close the voicemail after 2 minutes.
  update public.calls set state = 'ended', ended_at = now()
   where state = 'voicemail' and ring_until < now() - interval '2 minutes';
  return n;
end;
$$;

create function public.leave_voicemail(p_call_id uuid, p_audio_url text, p_duration_s numeric)
returns public.messages
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.calls;
  m public.messages;
begin
  select * into c from public.calls where id = p_call_id and caller_id = auth.uid() for update;
  if not found or c.state <> 'voicemail' then
    raise exception 'this call isn''t taking a message' using errcode = '55000';
  end if;
  insert into public.messages (apartment_id, sender_id, audio_url, duration_s, call_id)
  values (c.apartment_id, auth.uid(), p_audio_url, least(p_duration_s, 60), c.id)
  returning * into m;
  update public.calls set state = 'ended', ended_at = now(), end_reason = 'voicemail_left' where id = c.id;
  return m;
end;
$$;

-- Calling "as the home": a roommate who's home can join the caller's side.
create function public.join_call(p_call_id uuid)
returns public.calls
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.calls;
begin
  update public.calls
     set participants = array_append(participants, auth.uid())
   where id = p_call_id and state = 'active' and as_home is not null
     and public.is_member(as_home) and not (auth.uid() = any (participants))
  returning * into c;
  if not found then
    select * into c from public.calls where id = p_call_id and auth.uid() = any (participants);
    if not found then
      raise exception 'can''t join this call' using errcode = '42501';
    end if;
  end if;
  return c;
end;
$$;

create function public.end_call(p_call_id uuid)
returns public.calls
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.calls;
begin
  update public.calls
     set state = case when state = 'ringing' then 'missed' else 'ended' end::public.call_state,
         end_reason = case when state = 'ringing' then 'abandoned' else 'hung_up' end,
         ended_at = now()
   where id = p_call_id and state in ('ringing', 'active', 'voicemail')
     and (caller_id = auth.uid() or auth.uid() = any (participants))
  returning * into c;
  if not found then
    select * into c from public.calls where id = p_call_id;
  end if;
  return c;
end;
$$;

-- Which LiveKit room this person may enter for a call (null if none). The
-- caller joins while it rings, so answering connects instantly.
create function public.call_room(p_call_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select room_name from public.calls
   where id = p_call_id
     and (   (caller_id = auth.uid() and state in ('ringing', 'active'))  -- caller waits in the room
          or (auth.uid() = any (participants) and state = 'active'))
$$;

-- Cron backstop on Supabase (pg_cron); plain Postgres in tests skips it.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('expire-ringing-calls', '5 seconds', 'select public.expire_ringing_calls()');
  end if;
end $$;

revoke all on function public.ring_seconds(), public.start_call(uuid, uuid, uuid), public.call_fanout(uuid),
  public.settle_unanswered(public.calls), public.ring_out(uuid, boolean), public.expire_ringing_calls(),
  public.leave_voicemail(uuid, text, numeric), public.join_call(uuid), public.end_call(uuid),
  public.call_room(uuid)
  from public, anon, authenticated;

grant execute on function public.start_call(uuid, uuid, uuid)               to authenticated;
grant execute on function public.ring_out(uuid, boolean)                    to authenticated;
grant execute on function public.leave_voicemail(uuid, text, numeric)       to authenticated;
grant execute on function public.join_call(uuid)                            to authenticated;
grant execute on function public.end_call(uuid)                             to authenticated;
grant execute on function public.call_room(uuid)                            to authenticated;
-- call_fanout / expire_ringing_calls: service role only (Edge Function, cron).
grant execute on function public.call_fanout(uuid), public.expire_ringing_calls() to service_role;
