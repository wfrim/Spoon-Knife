-- Phase 0 gate: "over 3 days on 2+ phones, home/away matches reality at least
-- 95% of the time within 5 minutes; record any false 'home' from nearby spots."
--
-- Run in the Supabase SQL editor (or psql as the postgres role).
--
-- Ground truth = presence_checks (a tester tapped "I'm home"/"I'm away").
-- Prediction  = the newest geofence/heartbeat report the server had *received*
--               within 5 minutes after the check. Manual overrides are excluded
--               so they can't flatter the geofence.

with judged as (
  select c.id,
         c.device_id,
         d.name                as device,
         u.display_name        as tester,
         c.checked_at,
         c.actual,
         c.note,
         coalesce(g.state, 'unknown') as geofence_said
    from public.presence_checks c
    join public.devices d on d.id = c.device_id
    join public.users   u on u.id = c.user_id
    left join lateral (
      select e.state
        from public.presence_events e
       where e.device_id = c.device_id
         and e.source in ('geofence', 'heartbeat')
         and e.received_at <= c.checked_at + interval '5 minutes'
         and e.reported_at >= c.checked_at - public.presence_ttl()
       order by e.reported_at desc, e.id desc
       limit 1
    ) g on true
)

-- 1. Accuracy per phone and overall (gate: >= 95%).
select coalesce(device || ' (' || tester || ')', 'ALL PHONES')       as phone,
       count(*)                                                       as checks,
       count(*) filter (where geofence_said = actual)                 as correct,
       round(100.0 * count(*) filter (where geofence_said = actual) / nullif(count(*), 0), 1) as accuracy_pct,
       count(*) filter (where actual = 'away' and geofence_said = 'home') as false_home,
       count(*) filter (where actual = 'home' and geofence_said <> 'home') as missed_home,
       min(checked_at)::date                                          as first_day,
       max(checked_at)::date                                          as last_day
  from judged
 group by grouping sets ((device, tester), ())
 order by grouping(device, tester), 1;

-- 2. Every miss, newest first — false "home" notes show the café-downstairs cases.
-- select checked_at, device, tester, actual, geofence_said, note
--   from judged where geofence_said <> actual order by checked_at desc;

-- 3. Raw timeline for one phone, to eyeball crossing delays.
-- select reported_at, received_at, received_at - reported_at as delivery_lag,
--        state, source, applied, detail
--   from public.presence_events where device_id = '<device id>' order by reported_at;
