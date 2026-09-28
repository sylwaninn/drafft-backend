-- The outbox, production grade: policies (budget, backoff, expiry), circuit breakers per provider, the
-- dead-letter queue with its audited replay and discard, steps, atomic media verdicts, and alerts.
begin;
create extension if not exists pgtap with schema extensions;
select plan(55);

-- Delivery posts through pg_net: the Vault entries it needs, whatever this database has.
delete from vault.secrets where name in ('edge_functions_url', 'db_events_secret');
select vault.create_secret('http://functions.test', 'edge_functions_url');
select vault.create_secret('test-secret', 'db_events_secret');
-- A clean slate: nothing earlier in this database counts.
update private.outbox set delivered_at = now() where delivered_at is null;
update private.provider_circuits set state = 'closed', failures = 0, window_started_at = null, opened_at = null,
  retry_at = null, probe_at = null;
update private.ops_incidents set closed_at = now() where closed_at is null;

insert into private.staff (email, role) values ('sup@drafft.test', 'support'), ('boss@drafft.test', 'admin');

create function pg_temp.event(p_event text, p_age interval default '0') returns bigint language plpgsql as $$
declare
  v_id bigint;
begin
  insert into private.outbox (event, payload, created_at) values (p_event, '{}', now() - p_age) returning id into v_id;
  perform private.deliver(v_id);
  return v_id;
end $$;

create function pg_temp.row(p_id bigint) returns private.outbox language sql as $$
  select * from private.outbox where id = p_id;
$$;

create function pg_temp.fail_provider(p_provider text, p_times int) returns void language plpgsql as $$
begin
  for i in 1..p_times loop
    perform private.provider_failed(p_provider, 'resend 503');
  end loop;
end $$;

-- MARK: Policies

select is((private.outbox_policy('match.created')).retry_budget, interval '24 hours', 'an event has its own policy');
select is((private.outbox_policy('something.new')).event, '*', 'an unknown event gets the default');
select ok((select bool_and(private.outbox_backoff(1) between interval '15 seconds' and interval '30 seconds')
  from generate_series(1, 50)), 'the first retry comes after 15 to 30 seconds (jitter)');
select ok((select bool_and(private.outbox_backoff(30) between interval '30 minutes' and interval '1 hour')
  from generate_series(1, 50)), 'later ones are capped at an hour');

create temp table e as select pg_temp.event('match.created') as id;
select is((pg_temp.row((select id from e))).attempts, 1, 'a new event is posted at once');
select ok((pg_temp.row((select id from e))).deadline between now() + interval '23 hours' and now() + interval '25 hours',
  'with a 24 hour budget');
select ok((pg_temp.row((select id from e))).next_attempt_at > now(), 'and its next try later');
select is((select (convert_from(body, 'utf8')::jsonb ->> 'pushUntil')::timestamptz from net.http_request_queue order by id desc limit 1),
  (pg_temp.row((select id from e))).created_at + interval '1 hour', 'db-events is told until when a push is fresh');

-- A push-only event past its age is dropped, not sent late.
create temp table stale as select pg_temp.event('like.received', interval '3 hours') as id;
select is((pg_temp.row((select id from stale))).discard_reason, 'expired', 'a stale like push is dropped');
select is((pg_temp.row((select id from stale))).attempts, 0, 'without being sent');

-- MARK: Steps and acks

select public.outbox_step_done((select id from e), 'channel');
select public.outbox_step_done((select id from e), 'channel');
select is((pg_temp.row((select id from e))).steps, array['channel'], 'a step is recorded once');
select public.ack_event((select id from e));
select ok((pg_temp.row((select id from e))).delivered_at is not null, 'an ack delivers it (old signature still works)');

-- MARK: Circuit breaker

create temp table r as select pg_temp.event('support.created') as id;
select pg_temp.fail_provider('resend', 3);
select is((select state from private.provider_circuits where provider = 'resend'), 'closed', 'a few failures: still closed');
select public.outbox_failed((select id from r), 'resend 503', 'resend', true);
select is((pg_temp.row((select id from r))).attempts, 1, 'a failure below the threshold spends the attempt');
select public.outbox_failed((select id from r), 'resend 503', 'resend', true);
select is((select state from private.provider_circuits where provider = 'resend'), 'open', 'the fifth opens the circuit');
select is((pg_temp.row((select id from r))).attempts, 0, 'the failure that opened it gives the attempt back');
select is((pg_temp.row((select id from r))).waiting_for, 'resend', 'the event waits for the provider');
select ok((pg_temp.row((select id from r))).deadline > now() + interval '24 hours', 'its budget moves with the wait');

create temp table held as select pg_temp.event('report.created') as id;
select is((pg_temp.row((select id from held))).attempts, 0, 'a new event needing it is not posted');
select is((pg_temp.row((select id from held))).waiting_for, 'resend', 'it waits too');
create temp table other as select pg_temp.event('match.ended') as id;
select is((pg_temp.row((select id from other))).attempts, 1, 'other providers are not held');

-- The cooldown passes: half open, one probe.
update private.provider_circuits set retry_at = now() - interval '1 second' where provider = 'resend';
update private.outbox set next_attempt_at = now() - interval '1 second' where id in ((select id from r), (select id from held));
select private.retry_outbox();
select is((select state from private.provider_circuits where provider = 'resend'), 'half_open', 'the cooldown over, it is half open');
select is((select count(*) from private.outbox where id in ((select id from r), (select id from held)) and attempts = 1),
  1::bigint, 'one event goes through as the probe');
select public.outbox_failed((select id from r), 'resend 503', 'resend', true);
select is((select state from private.provider_circuits where provider = 'resend'), 'open', 'a failed probe opens it again');
select is((select cooldown from private.provider_circuits where provider = 'resend'), interval '2 minutes', 'for longer');
select public.ack_event((select id from held), array['resend']);
select is((select state from private.provider_circuits where provider = 'resend'), 'closed', 'a success closes it');

-- Twilio, outside the outbox.
select public.provider_report('twilio', false, 'twilio 500');
select is((select failures from private.provider_circuits where provider = 'twilio'), 1, 'the SMS hook reports to its circuit');

-- MARK: Dead letters

create temp table dead as select pg_temp.event('push.preferences') as id;
update private.outbox set deadline = now() - interval '1 second' where id = (select id from dead);
select public.outbox_failed((select id from dead), 'stream 400: bad request', 'stream', false);
select ok((pg_temp.row((select id from dead))).failed_at is not null, 'out of budget, a failure is final');
select is((select state from private.provider_circuits where provider = 'stream'), 'closed', 'a refusal does not open a circuit');
select is((pg_temp.row((select id from dead))).last_error, 'stream 400: bad request', 'the error is kept for the team');

create temp table silent as select pg_temp.event('media.deleted') as id;
update private.outbox set deadline = now() - interval '1 second', next_attempt_at = now() - interval '1 second'
  where id = (select id from silent);
select private.retry_outbox();
select ok((pg_temp.row((select id from silent))).failed_at is not null, 'no answer past the budget fails it too');

select throws_ok($$select public.admin_failed_events('sup@drafft.test')$$, 'P0001', 'not allowed', 'support sees no failed events');
select is((public.admin_failed_events('boss@drafft.test') ->> 'total')::int, 2, 'an admin sees them');
select throws_ok($$select public.admin_replay_events('sup@drafft.test', array[1::bigint])$$, 'P0001', 'not allowed',
  'support replays nothing');

select public.outbox_step_done((select id from dead), 'stream-user');
select is(public.admin_replay_events('boss@drafft.test', array[(select id from dead), (select id from e)], 'stream fixed'), 1,
  'a replay takes failed events only');
select ok((pg_temp.row((select id from dead))).failed_at is null and (pg_temp.row((select id from dead))).attempts = 1,
  'the event is sent again at once');
select is((pg_temp.row((select id from dead))).steps, array['stream-user'], 'steps already done stay done');
select ok((pg_temp.row((select id from dead))).deadline > now() + interval '23 hours', 'with a fresh budget');
select is((select count(*) from private.admin_audit where action = 'events.replay' and target = 'outbox:' || (select id from dead)
    and actor = 'boss@drafft.test' and reason = 'stream fixed'), 1::bigint, 'the replay is audited');

select throws_ok(format($$select public.admin_discard_events('boss@drafft.test', array[%s::bigint], ' ')$$, (select id from silent)),
  'P0001', 'say why', 'discarding needs a reason');
select is(public.admin_discard_events('boss@drafft.test', array[(select id from silent)], 'keys already gone'), 1, 'discarded');
select is((pg_temp.row((select id from silent))).discarded_by, 'boss@drafft.test', 'by whom');
select is((select count(*) from private.admin_audit where action = 'events.discard'), 1::bigint, 'and audited');

-- MARK: Live

select ok((select count(*) from realtime.messages where topic = 'staff:queues' and payload ->> 'queue' = 'events') > 0,
  'sophros hears the dead-letter queue change');

-- MARK: Alerts

delete from private.ops_alerts;
update private.outbox set failed_at = now() - interval '2 hours', last_error = 'x', discarded_at = null, delivered_at = null
  where id = (select id from silent);
select private.ops_check();
select private.ops_check();
select is((select count(*) from private.ops_alerts where kind = 'incident'), 1::bigint, 'one email per incident');
select is((select count(*) from private.ops_alerts where kind = 'reminder'), 1::bigint, 'one reminder past an hour');
select ok(not ((select payload::text from private.ops_alerts where kind = 'incident') ~ '(@|stream 400|"x")'),
  'alerts carry counts, not addresses or error texts');
update private.outbox set delivered_at = now() where delivered_at is null;
update private.provider_circuits set state = 'closed';
select private.ops_check();
select ok((select closed_at from private.ops_incidents order by id desc limit 1) is not null, 'all clear closes the incident');

-- MARK: Media verdicts

create temp table who as select gen_random_uuid() as id;
insert into auth.users (id, email, aud, role, instance_id)
  select id, 'mia@outbox.test', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000' from who;
insert into public.profile_media (user_id, key, position, width, height)
  select id, 'u/' || id || '/photos/1.jpg', 0, 1200, 1600 from who;
insert into public.profile_media (user_id, key, position, width, height)
  select id, 'u/' || id || '/photos/2.jpg', 1, 1200, 1600 from who;
create temp table pm as select id, key from public.profile_media where user_id = (select id from who);

select ok(public.apply_media_verdict((select id from pm where key like '%1.jpg'), 'rejected', array['Explicit']),
  'a verdict on a pending photo applies');
select ok((select status = 'rejected' from public.profile_media where id = (select id from pm where key like '%1.jpg'))
  and (select count(*) = 1 from public.media_flags where key = (select key from pm where key like '%1.jpg')),
  'the refusal and its flag together');
select ok(not public.apply_media_verdict((select id from pm where key like '%1.jpg'), 'rejected', array['Explicit']),
  'a retry decides nothing again');
select is((select count(*) from public.media_flags where key = (select key from pm where key like '%1.jpg')), 1::bigint,
  'and flags nothing twice');
select public.apply_media_verdict((select id from pm where key like '%2.jpg'), 'review', array['Weapons']);
select public.apply_media_verdict((select id from pm where key like '%2.jpg'), 'review', array['Weapons']);
select is((select count(*) from public.media_flags where key = (select key from pm where key like '%2.jpg')), 1::bigint,
  'a borderline photo stays pending, flagged once whatever the retries');
select is((select status::text from public.profile_media where id = (select id from pm where key like '%2.jpg')), 'pending',
  'still pending for a person');
select throws_ok(format($$select public.apply_media_verdict(%L, 'maybe')$$, (select id from pm where key like '%2.jpg')),
  'P0001', 'approved, rejected or review', 'an unknown verdict is refused');

select * from finish();
rollback;
