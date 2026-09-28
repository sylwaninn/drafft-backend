-- Session reminders are sent by the server now, no longer scheduled on the phone (supersedes the note in
-- 20260924000013). A local reminder outlived its session: a cancel, an unmatch, a ban or a deletion can't
-- reliably reach an app that isn't running (silent pushes are throttled and never wake a force-quit app),
-- nor the person's other devices, so the reminder still went off. Here the state is checked when the
-- reminder is due, and again when db-events sends it: a session that isn't accepted any more, or whose
-- match ended, sends nothing.
--
-- Two reminders per person and accepted session, each following its setting on the profile:
-- - `evening`: 20:00 the evening before, in the person's time zone (their latest device's), computed with
--   the time zone database so a daylight saving change in between is handled; skipped when it would fall
--   less than an hour before the session;
-- - `hour`: an hour before.
-- A cron job queues them every minute; each is queued once (private.session_reminders) and its push is
-- dropped when it would arrive late (outbox policy). A paused account keeps its reminders (decision 3.1).

create table private.session_reminders (
  session_id uuid not null references public.sessions (id) on delete cascade,
  user_id uuid not null,
  kind text not null check (kind in ('evening', 'hour')),
  queued_at timestamptz not null default now(),
  primary key (session_id, user_id, kind)
);

alter table private.session_reminders enable row level security;

-- Upcoming accepted sessions are few; the partial index keeps the minute-by-minute scan cheap.
create index sessions_accepted_upcoming_idx on public.sessions (chosen_at) where status = 'accepted';

-- 20:00 local time the evening before a session, as an instant. Local dates and times go through the time
-- zone database, so a clock change between that evening and the session is handled.
create function private.session_evening(p_at timestamptz, p_tz text)
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select (((p_at at time zone p_tz)::date - 1) + time '20:00') at time zone p_tz;
$$;

create function private.queue_session_reminders()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_count integer := 0;
begin
  for r in
    with due as (
      select s.id as session_id, s.match_id, s.chosen_at, p.id as user_id, p.language,
        p.notify_session_evening, p.notify_session_hour_before,
        coalesce((
          select d.timezone from private.devices d
          where d.user_id = p.id and d.timezone <> ''
            and exists (select 1 from pg_catalog.pg_timezone_names z where z.name = d.timezone)
          order by d.last_seen_at desc limit 1), 'UTC') as tz
      from public.sessions s
      join public.matches m on m.id = s.match_id and m.ended_at is null
      join public.profiles p on p.id in (m.user_a, m.user_b) and p.deleted_at is null
      where s.status = 'accepted'
        and s.chosen_at > now()
        and s.chosen_at < now() + interval '2 days'
    ),
    candidates as (
      select session_id, match_id, chosen_at, user_id, language, tz, 'hour'::text as kind
      from due
      where notify_session_hour_before
        and now() >= chosen_at - interval '1 hour' and now() < chosen_at - interval '45 minutes'
      union all
      select session_id, match_id, chosen_at, user_id, language, tz, 'evening'
      from due
      cross join lateral (
        select private.session_evening(chosen_at, tz) as evening) e
      where notify_session_evening
        and e.evening < chosen_at - interval '1 hour'
        and now() >= e.evening and now() < e.evening + interval '30 minutes'
    ),
    queued as (
      insert into private.session_reminders (session_id, user_id, kind)
      select session_id, user_id, kind from candidates
      on conflict do nothing
      returning session_id, user_id, kind
    )
    select c.* from queued q
    join candidates c using (session_id, user_id, kind)
  loop
    perform private.emit('session.reminder', jsonb_build_object(
      'sessionId', r.session_id, 'matchId', r.match_id, 'to', r.user_id, 'kind', r.kind,
      'at', r.chosen_at, 'language', r.language, 'timezone', r.tz));
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

revoke execute on function private.queue_session_reminders(), private.session_evening(timestamptz, text) from public, anon, authenticated;

insert into private.outbox_policies (event, retry_budget, expires_after, push_ttl, providers)
values ('session.reminder', '1 hour', '30 minutes', '20 minutes', '{apns}');

select cron.schedule('session-reminders', '* * * * *', 'select private.queue_session_reminders()');
