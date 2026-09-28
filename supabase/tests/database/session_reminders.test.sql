-- Session reminders are queued by the server: an hour before and the evening before, once each, only for
-- accepted sessions of an active match, following each person's settings (paused or not).
begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

create function pg_temp.person(p_email text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id)
  values (v_id, p_email, 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  return v_id;
end $$;

create function pg_temp.session(p_a uuid, p_b uuid, p_at timestamptz, p_status public.session_status)
returns uuid language plpgsql as $$
declare
  v_match uuid;
  v_id uuid;
begin
  insert into public.matches (user_a, user_b) values (least(p_a, p_b), greatest(p_a, p_b)) returning id into v_match;
  insert into public.sessions (match_id, proposer_id, sport_id, options, chosen_at, status)
  values (v_match, p_a, 'running', array[p_at], case when p_status = 'accepted' then p_at end, p_status)
  returning id into v_id;
  return v_id;
end $$;

create function pg_temp.reminders(p_session uuid) returns text language sql as $$
  select coalesce(string_agg((payload ->> 'kind'), ',' order by payload ->> 'to'), '')
  from private.outbox where event = 'session.reminder' and payload ->> 'sessionId' = p_session::text;
$$;

create temp table ids as select pg_temp.person('ana@test.dev') as ana, pg_temp.person('bo@test.dev') as bo,
  pg_temp.person('cy@test.dev') as cy, pg_temp.person('di@test.dev') as di;
update public.profiles set notify_session_hour_before = false where id = (select di from ids);
update public.profiles set paused = true where id = (select bo from ids);
create temp table s as select
  pg_temp.session((select ana from ids), (select bo from ids), now() + interval '50 minutes', 'accepted') as soon,
  pg_temp.session((select ana from ids), (select cy from ids), now() + interval '50 minutes', 'cancelled') as cancelled,
  pg_temp.session((select cy from ids), (select di from ids), now() + interval '50 minutes', 'accepted') as half_off,
  pg_temp.session((select bo from ids), (select cy from ids), now() + interval '3 hours', 'accepted') as later;

select ok(private.queue_session_reminders() >= 3, 'the due reminders are queued');
select is(pg_temp.reminders((select soon from s)), 'hour,hour', 'an hour before, to both, paused included');
select is(pg_temp.reminders((select cancelled from s)), '', 'nothing for a cancelled session');
select is(pg_temp.reminders((select half_off from s)), 'hour', 'nothing for whoever turned it off');
select is(pg_temp.reminders((select later from s)), '', 'not before its time');
select is(private.queue_session_reminders(), 0, 'each reminder is queued once');

-- The evening before, local time, across the switch to winter time in Paris (25 October 2026).
select is(private.session_evening('2026-10-25T06:00:00Z', 'Europe/Paris'), '2026-10-24T18:00:00Z'::timestamptz,
  '20:00 summer time the evening before a winter-time session');
select is(private.session_evening('2026-10-26T06:00:00Z', 'Europe/Paris'), '2026-10-25T19:00:00Z'::timestamptz,
  '20:00 winter time once the clocks went back');
select is(private.session_evening('2026-03-29T05:00:00Z', 'Europe/Paris'), '2026-03-28T19:00:00Z'::timestamptz,
  '20:00 winter time the evening before the switch to summer time');

select ok(not has_function_privilege('authenticated', 'private.queue_session_reminders()', 'execute'),
  'members cannot queue reminders');

select * from finish();
rollback;
