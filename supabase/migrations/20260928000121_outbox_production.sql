-- The outbox, production grade (decision 4.7). What changes:
--
-- - A policy per event: a retry budget (~24 h), an exponential delay with jitter between attempts, and an
--   age after which a push or a push-only event is stale and dropped instead of sent late.
-- - A circuit breaker per provider (Stream, APNs, Resend, Twilio, R2): repeated transient failures open it,
--   the events that need it wait without spending their attempts or their budget, one probe closes it.
-- - A dead-letter queue: an event out of budget is marked failed, never retried by itself; an admin
--   replays or discards it from sophros (admin_*_events), and each decision is audited.
-- - Steps: db-events records each side effect it completed (`steps`), so a retry or a replay runs only
--   what's missing. Handlers stay idempotent on their own (deterministic ids, provider idempotency keys);
--   the steps close the window between two effects of the same event.
-- - Alerts, out of db-events: one email per incident, one reminder when it's over an hour old, one summary
--   a day, to SUPPORT_INBOX through the ops-alert function. Counts, event names and providers only: never
--   a payload, an address or an error text.

-- MARK: Policies

create table private.outbox_policies (
  -- '*' is the default, for any event without its own row.
  event text primary key,
  retry_budget interval not null default interval '24 hours' check (retry_budget between interval '1 minute' and interval '7 days'),
  -- The whole event is useless after this (a push and nothing else): dropped, not failed.
  expires_after interval check (expires_after > interval '0'),
  -- The pushes inside the event are skipped after this; its other effects still happen.
  push_ttl interval check (push_ttl > interval '0'),
  providers text[] not null default '{}'
    check (providers <@ array['stream', 'apns', 'resend', 'twilio', 'r2'])
);

insert into private.outbox_policies (event, retry_budget, expires_after, push_ttl, providers) values
  ('*', '24 hours', null, '1 hour', '{}'),
  ('like.received', '2 hours', '2 hours', '2 hours', '{apns}'),
  ('match.created', '24 hours', null, '1 hour', '{stream,apns}'),
  ('match.ended', '24 hours', null, null, '{stream}'),
  ('session.proposed', '24 hours', null, '1 hour', '{stream,apns}'),
  ('session.accepted', '24 hours', null, '1 hour', '{stream,apns}'),
  ('session.declined', '24 hours', null, '1 hour', '{stream,apns}'),
  ('session.cancelled', '24 hours', null, '1 hour', '{stream,apns}'),
  ('session.auto_cancelled', '24 hours', null, '6 hours', '{stream,apns}'),
  ('media.created', '24 hours', null, '6 hours', '{r2,apns}'),
  ('media.deleted', '24 hours', null, null, '{r2}'),
  ('media.reviewed', '24 hours', null, '6 hours', '{apns,resend}'),
  ('media.approved_on_review', '24 hours', null, null, '{resend}'),
  ('push.preferences', '24 hours', null, null, '{stream}'),
  ('profile.paused', '24 hours', null, null, '{stream}'),
  ('account.moderation', '24 hours', null, null, '{stream,resend}'),
  ('support.created', '24 hours', null, null, '{resend}'),
  ('support.reply', '24 hours', null, null, '{resend}'),
  ('report.created', '24 hours', null, null, '{resend}'),
  ('export.requested', '24 hours', null, null, '{resend}'),
  ('selfie.delete', '24 hours', null, null, '{}'),
  ('boost.weekly', '12 hours', '12 hours', '12 hours', '{apns}');

create function private.outbox_policy(p_event text)
returns private.outbox_policies
language sql
stable
security definer
set search_path = ''
as $$
  select * from private.outbox_policies where event in (p_event, '*') order by event = '*' limit 1;
$$;

-- Exponential, capped at an hour, with jitter (half to full delay) so a recovered provider isn't hit
-- by every waiting event in the same second. Attempt 1 waits ~30 s, 2 ~1 min, ... 8 and on ~1 h.
create function private.outbox_backoff(p_attempt int)
returns interval
language sql
volatile
set search_path = ''
as $$
  select least(interval '1 hour', interval '30 seconds' * power(2, least(greatest(p_attempt - 1, 0), 20)))
    * (0.5 + random() * 0.5);
$$;

-- MARK: Outbox columns

alter table private.outbox
  add column next_attempt_at timestamptz not null default now(),
  add column deadline timestamptz,
  add column steps text[] not null default '{}',
  add column last_error text check (char_length(last_error) <= 1000),
  add column last_provider text,
  add column waiting_for text,
  add column failed_at timestamptz,
  add column discarded_at timestamptz,
  add column discarded_by text,
  add column discard_reason text check (char_length(discard_reason) <= 1000),
  add column replays int not null default 0;

-- Rows already waiting keep their place; those the old rule gave up on (10 attempts) are the first
-- entries of the dead-letter queue.
update private.outbox o
  set deadline = o.created_at + (private.outbox_policy(o.event)).retry_budget,
      next_attempt_at = coalesce(o.last_attempt_at, o.created_at)
  where o.delivered_at is null;
update private.outbox
  set failed_at = now(), last_error = 'gave up after 10 attempts (before retry budgets)'
  where delivered_at is null and attempts >= 10;

create function private.outbox_defaults()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.deadline := coalesce(new.deadline, new.created_at + (private.outbox_policy(new.event)).retry_budget);
  return new;
end;
$$;

create trigger outbox_defaults before insert on private.outbox
  for each row execute function private.outbox_defaults();

drop index private.outbox_pending_idx;
create index outbox_due_idx on private.outbox (next_attempt_at)
  where delivered_at is null and failed_at is null and discarded_at is null;
create index outbox_failed_idx on private.outbox (failed_at)
  where failed_at is not null and delivered_at is null and discarded_at is null;

-- MARK: Circuit breakers

create table private.provider_circuits (
  provider text primary key check (provider in ('stream', 'apns', 'resend', 'twilio', 'r2')),
  state text not null default 'closed' check (state in ('closed', 'open', 'half_open')),
  -- Transient failures in the current window (2 min); 5 open the circuit.
  failures int not null default 0,
  window_started_at timestamptz,
  opened_at timestamptz,
  retry_at timestamptz,
  -- 1 min, doubled by each failed probe, up to 15 min.
  cooldown interval not null default interval '1 minute',
  -- The one event let through while half open.
  probe_at timestamptz,
  last_error text check (char_length(last_error) <= 1000),
  updated_at timestamptz not null default now()
);

insert into private.provider_circuits (provider) values ('stream'), ('apns'), ('resend'), ('twilio'), ('r2');

-- A transient failure (5xx, 429, timeout, network) of a provider.
create function private.provider_failed(p_provider text, p_error text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  c private.provider_circuits;
begin
  select * into c from private.provider_circuits where provider = p_provider for update;
  if not found then
    return;
  end if;
  if c.state = 'half_open' then
    -- The probe failed: open again, for longer.
    update private.provider_circuits
      set state = 'open', probe_at = null, cooldown = least(c.cooldown * 2, interval '15 minutes'),
          retry_at = now() + least(c.cooldown * 2, interval '15 minutes'), last_error = left(p_error, 1000),
          updated_at = now()
      where provider = p_provider;
  elsif c.state = 'open' then
    update private.provider_circuits set last_error = left(p_error, 1000), updated_at = now()
      where provider = p_provider;
  elsif c.window_started_at is null or c.window_started_at < now() - interval '2 minutes' then
    update private.provider_circuits
      set failures = 1, window_started_at = now(), last_error = left(p_error, 1000), updated_at = now()
      where provider = p_provider;
  elsif c.failures + 1 >= 5 then
    update private.provider_circuits
      set state = 'open', failures = c.failures + 1, opened_at = now(), cooldown = interval '1 minute',
          retry_at = now() + interval '1 minute', last_error = left(p_error, 1000), updated_at = now()
      where provider = p_provider;
  else
    update private.provider_circuits set failures = c.failures + 1, last_error = left(p_error, 1000), updated_at = now()
      where provider = p_provider;
  end if;
end;
$$;

-- A call that worked closes the circuit (a successful probe) and clears the window.
create function private.provider_ok(p_provider text)
returns void
language sql
security definer
set search_path = ''
as $$
  update private.provider_circuits
    set state = 'closed', failures = 0, window_started_at = null, opened_at = null, retry_at = null,
        cooldown = interval '1 minute', probe_at = null, updated_at = now()
    where provider = p_provider and (state <> 'closed' or failures > 0);
$$;

-- The first of these providers that can't be used now, or null. A half-open circuit lets one probe
-- through every 2 minutes: the caller that gets null here holds it.
create function private.provider_blocker(p_providers text[])
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  c private.provider_circuits;
begin
  for c in select * from private.provider_circuits where provider = any (p_providers) and state <> 'closed'
    order by provider
  loop
    if c.state = 'open' and c.retry_at > now() then
      return c.provider;
    end if;
    update private.provider_circuits
      set state = 'half_open', probe_at = now(), updated_at = now()
      where provider = c.provider and (probe_at is null or probe_at < now() - interval '2 minutes');
    if not found then
      return c.provider;
    end if;
  end loop;
  return null;
end;
$$;

-- When the blocked provider may be tried again.
create function private.provider_retry_at(p_provider text)
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select case when state = 'open' then greatest(retry_at, now() + interval '5 seconds')
              else coalesce(probe_at, now()) + interval '2 minutes' end
  from private.provider_circuits where provider = p_provider;
$$;

-- MARK: Delivery

-- Holds an event while a provider it needs is down: no attempt spent, and the budget moves with the wait.
create function private.outbox_wait(p_id bigint, p_provider text)
returns void
language sql
security definer
set search_path = ''
as $$
  update private.outbox
    set waiting_for = p_provider,
        deadline = deadline + greatest(private.provider_retry_at(p_provider) - greatest(next_attempt_at, now()), interval '0'),
        next_attempt_at = private.provider_retry_at(p_provider)
    where id = p_id;
$$;

-- Posts one outbox row to the db-events function. The URL and shared secret come from Vault
-- (`edge_functions_url`, `db_events_secret`), so no environment-specific value lives in migrations.
-- Stale push-only events are dropped here; an event whose provider is down waits for it.
create or replace function private.deliver(p_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
  v_secret text;
  v_policy private.outbox_policies;
  v_blocker text;
  o private.outbox;
begin
  select * into o from private.outbox
    where id = p_id and delivered_at is null and failed_at is null and discarded_at is null;
  if o.id is null then
    return;
  end if;
  v_policy := private.outbox_policy(o.event);
  if v_policy.expires_after is not null and o.created_at + v_policy.expires_after < now() then
    update private.outbox set discarded_at = now(), discard_reason = 'expired' where id = p_id;
    return;
  end if;
  v_blocker := private.provider_blocker(v_policy.providers);
  if v_blocker is not null then
    perform private.outbox_wait(p_id, v_blocker);
    return;
  end if;
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'edge_functions_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'db_events_secret';
  if v_url is null or v_secret is null then
    raise warning 'outbox %: vault secrets edge_functions_url / db_events_secret missing', p_id;
    return;
  end if;
  update private.outbox
    set attempts = attempts + 1, last_attempt_at = now(), waiting_for = null,
        next_attempt_at = now() + private.outbox_backoff(attempts + 1)
    where id = p_id
    returning * into o;
  perform net.http_post(
    url := v_url || '/db-events',
    body := jsonb_build_object('id', o.id, 'event', o.event, 'payload', o.payload,
      'createdAt', o.created_at, 'attempt', o.attempts, 'steps', to_jsonb(o.steps),
      'pushUntil', o.created_at + v_policy.push_ttl),
    headers := jsonb_build_object('content-type', 'application/json', 'x-webhook-secret', v_secret),
    timeout_milliseconds := 10000);
end;
$$;

-- Called by db-events once an event is fully handled. `p_providers`: the providers it reached.
drop function public.ack_event(bigint);
create function public.ack_event(p_id bigint, p_providers text[] default '{}')
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_provider text;
begin
  -- Also a late answer to an event given up on: it did happen.
  update private.outbox
    set delivered_at = now(), failed_at = null, waiting_for = null, last_error = null
    where id = p_id and delivered_at is null and discarded_at is null;
  foreach v_provider in array coalesce(p_providers, '{}') loop
    perform private.provider_ok(v_provider);
  end loop;
end;
$$;

-- Called by db-events when a handler threw. `p_provider` and `p_transient`: the provider that failed
-- and whether it was down (5xx, 429, timeout) rather than refusing this event. Its circuit counts it;
-- once open, the event waits without spending the attempt. Out of budget: failed, for the team.
create function public.outbox_failed(
  p_id bigint, p_error text, p_provider text default null, p_transient boolean default false,
  p_providers text[] default '{}'
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_provider text;
  v_blocker text;
begin
  foreach v_provider in array coalesce(p_providers, '{}') loop
    perform private.provider_ok(v_provider);
  end loop;
  update private.outbox
    set last_error = left(coalesce(p_error, 'unknown error'), 1000), last_provider = p_provider
    where id = p_id and delivered_at is null and discarded_at is null;
  if not found then
    return;
  end if;
  if p_provider is not null and p_transient then
    perform private.provider_failed(p_provider, p_error);
    select provider into v_blocker from private.provider_circuits
      where provider = p_provider and state = 'open' and retry_at > now();
    if v_blocker is not null then
      update private.outbox set attempts = greatest(attempts - 1, 0) where id = p_id;
      perform private.outbox_wait(p_id, v_blocker);
      return;
    end if;
  end if;
  update private.outbox set failed_at = now()
    where id = p_id and failed_at is null and deadline <= now();
end;
$$;

-- Called by db-events after each side effect of an event, so a retry skips it.
create function public.outbox_step_done(p_id bigint, p_step text)
returns void
language sql
security definer
set search_path = ''
as $$
  update private.outbox set steps = array_append(steps, left(p_step, 200))
    where id = p_id and not (left(p_step, 200) = any (steps));
$$;

-- A provider reached outside the outbox (Twilio from the SMS hook): its circuit hears about it.
create function public.provider_report(p_provider text, p_ok boolean, p_error text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_ok then
    perform private.provider_ok(p_provider);
  else
    perform private.provider_failed(p_provider, coalesce(p_error, 'failed'));
  end if;
end;
$$;

revoke execute on function public.ack_event(bigint, text[]), public.outbox_failed(bigint, text, text, boolean, text[]),
  public.outbox_step_done(bigint, text), public.provider_report(text, boolean, text)
  from public, anon, authenticated;
grant execute on function public.ack_event(bigint, text[]), public.outbox_failed(bigint, text, text, boolean, text[]),
  public.outbox_step_done(bigint, text), public.provider_report(text, boolean, text)
  to service_role;

revoke all on function private.outbox_policy(text), private.outbox_backoff(int), private.provider_failed(text, text),
  private.provider_ok(text), private.provider_blocker(text[]), private.provider_retry_at(text),
  private.outbox_wait(bigint, text), private.outbox_defaults() from public, anon, authenticated;

-- Every minute: circuits past their cooldown turn half open, events out of budget fail, stale push-only
-- events are dropped, and up to 500 due events are posted, oldest due first.
create or replace function private.retry_outbox()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
begin
  update private.provider_circuits set state = 'half_open', probe_at = null, updated_at = now()
    where state = 'open' and retry_at <= now();

  update private.outbox
    set failed_at = now(), last_error = coalesce(last_error, 'no answer from db-events')
    where delivered_at is null and failed_at is null and discarded_at is null
      and next_attempt_at <= now() and deadline <= now();

  for v_id in
    select id from private.outbox
    where delivered_at is null and failed_at is null and discarded_at is null and next_attempt_at <= now()
    order by next_attempt_at
    limit 500
    for update skip locked
  loop
    perform private.deliver(v_id);
  end loop;
end;
$$;

-- Delivered rows go after 7 days (unchanged); dropped and discarded ones after 30. Failed rows stay until
-- someone decides.
select cron.unschedule('outbox-cleanup');
select cron.schedule('outbox-cleanup', '17 3 * * *', $$
  delete from private.outbox where delivered_at < now() - interval '7 days';
  delete from private.outbox where discarded_at < now() - interval '30 days';
$$);

-- MARK: Alerts

-- An incident: from the first sign of trouble (a failed event, an open circuit, an event waiting over
-- 30 minutes) until none is left.
create table private.ops_incidents (
  id bigint generated always as identity primary key,
  opened_at timestamptz not null default now(),
  reminded_at timestamptz,
  closed_at timestamptz
);

create unique index ops_incidents_one_open on private.ops_incidents ((true)) where closed_at is null;

-- Emails to SUPPORT_INBOX, posted to the ops-alert function (not db-events: it must work when db-events
-- doesn't). `payload`: counts, event names and providers, nothing personal.
create table private.ops_alerts (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('incident', 'reminder', 'daily')),
  incident_id bigint references private.ops_incidents (id),
  payload jsonb not null,
  attempts int not null default 0,
  sent_at timestamptz,
  created_at timestamptz not null default now()
);

create index ops_alerts_unsent_idx on private.ops_alerts (id) where sent_at is null;
create index ops_alerts_incident_idx on private.ops_alerts (incident_id);

-- The outbox right now, without any personal data.
create function private.ops_state()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'failed', (select count(*) from private.outbox
               where failed_at is not null and delivered_at is null and discarded_at is null),
    'failedByEvent', coalesce((select jsonb_object_agg(event, n) from (
        select event, count(*) as n from private.outbox
        where failed_at is not null and delivered_at is null and discarded_at is null group by event) f), '{}'),
    'oldestFailedAt', (select min(failed_at) from private.outbox
                       where failed_at is not null and delivered_at is null and discarded_at is null),
    'waiting', (select count(*) from private.outbox
                where delivered_at is null and failed_at is null and discarded_at is null and waiting_for is not null),
    'late', (select count(*) from private.outbox
             where delivered_at is null and failed_at is null and discarded_at is null
               and created_at < now() - interval '30 minutes'),
    'oldestLateAt', (select min(created_at) from private.outbox
                     where delivered_at is null and failed_at is null and discarded_at is null
                       and created_at < now() - interval '30 minutes'),
    'openCircuits', coalesce((select jsonb_agg(provider order by provider) from private.provider_circuits
                              where state <> 'closed'), '[]'),
    'oldestOpenCircuitAt', (select min(opened_at) from private.provider_circuits where state <> 'closed'));
$$;

-- Posts one alert to ops-alert, which emails it and calls ack_ops_alert.
create function private.send_ops_alert(p_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
  v_secret text;
  a private.ops_alerts;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'edge_functions_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'db_events_secret';
  if v_url is null or v_secret is null then
    raise warning 'ops alert %: vault secrets edge_functions_url / db_events_secret missing', p_id;
    return;
  end if;
  update private.ops_alerts set attempts = attempts + 1 where id = p_id and sent_at is null returning * into a;
  if a.id is null then
    return;
  end if;
  perform net.http_post(
    url := v_url || '/ops-alert',
    body := jsonb_build_object('id', a.id, 'kind', a.kind, 'incident', a.incident_id, 'payload', a.payload),
    headers := jsonb_build_object('content-type', 'application/json', 'x-webhook-secret', v_secret),
    timeout_milliseconds := 10000);
end;
$$;

create function private.queue_ops_alert(p_kind text, p_incident bigint, p_payload jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
begin
  insert into private.ops_alerts (kind, incident_id, payload) values (p_kind, p_incident, p_payload)
    returning id into v_id;
  perform private.send_ops_alert(v_id);
end;
$$;

-- Every minute: opens an incident at the first sign of trouble (one email), reminds once when the oldest
-- problem is over an hour old, closes it when everything is clear. Unsent alerts are posted again (5 tries).
create function private.ops_check()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_state jsonb := private.ops_state();
  v_trouble boolean;
  v_oldest timestamptz;
  v_incident private.ops_incidents;
  v_id bigint;
begin
  v_trouble := (v_state ->> 'failed')::int > 0 or (v_state ->> 'late')::int > 0
    or jsonb_array_length(v_state -> 'openCircuits') > 0;
  v_oldest := least((v_state ->> 'oldestFailedAt')::timestamptz, (v_state ->> 'oldestLateAt')::timestamptz,
    (v_state ->> 'oldestOpenCircuitAt')::timestamptz);
  select * into v_incident from private.ops_incidents where closed_at is null for update;

  if v_trouble and v_incident.id is null then
    insert into private.ops_incidents default values returning * into v_incident;
    perform private.queue_ops_alert('incident', v_incident.id, v_state);
  elsif v_trouble and v_incident.reminded_at is null and v_oldest < now() - interval '1 hour' then
    update private.ops_incidents set reminded_at = now() where id = v_incident.id;
    perform private.queue_ops_alert('reminder', v_incident.id,
      v_state || jsonb_build_object('openedAt', v_incident.opened_at));
  elsif not v_trouble and v_incident.id is not null then
    update private.ops_incidents set closed_at = now() where id = v_incident.id;
  end if;

  for v_id in
    select id from private.ops_alerts
    where sent_at is null and attempts < 5 and created_at > now() - interval '1 day'
      and created_at < now() - interval '1 minute'
    order by id
  loop
    perform private.send_ops_alert(v_id);
  end loop;
end;
$$;

-- Every morning: the last 24 hours, and what's still open.
create function private.ops_daily()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.queue_ops_alert('daily', null, private.ops_state() || jsonb_build_object(
    'delivered', (select count(*) from private.outbox where delivered_at > now() - interval '1 day'),
    'expired', (select count(*) from private.outbox
                where discarded_at > now() - interval '1 day' and discard_reason = 'expired'),
    'discarded', (select count(*) from private.outbox
                  where discarded_at > now() - interval '1 day' and discarded_by is not null),
    'newlyFailed', (select count(*) from private.outbox where failed_at > now() - interval '1 day'),
    'incidents', (select count(*) from private.ops_incidents where opened_at > now() - interval '1 day')));
end;
$$;

-- Called by ops-alert once the email is sent.
create function public.ack_ops_alert(p_id bigint)
returns void
language sql
security definer
set search_path = ''
as $$
  update private.ops_alerts set sent_at = now() where id = p_id and sent_at is null;
$$;

revoke all on function private.ops_state(), private.send_ops_alert(bigint), private.queue_ops_alert(text, bigint, jsonb),
  private.ops_check(), private.ops_daily() from public, anon, authenticated;
revoke execute on function public.ack_ops_alert(bigint) from public, anon, authenticated;
grant execute on function public.ack_ops_alert(bigint) to service_role;

select cron.schedule('ops-check', '* * * * *', 'select private.ops_check()');
select cron.schedule('ops-daily', '0 7 * * *', 'select private.ops_daily()');
select cron.schedule('ops-alerts-cleanup', '37 3 * * *', $$
  delete from private.ops_alerts where created_at < now() - interval '90 days';
$$);

-- MARK: sophros

-- The failed events and the circuits, for the "Failed events" page. Admins only: payloads name accounts.
create function public.admin_failed_events(p_actor text, p_limit int default 100, p_offset int default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_staff(p_actor, 'admin');
  return jsonb_build_object(
    'events', coalesce((
      select jsonb_agg(jsonb_build_object('id', o.id, 'event', o.event, 'payload', o.payload,
          'attempts', o.attempts, 'replays', o.replays, 'createdAt', o.created_at, 'failedAt', o.failed_at,
          'lastError', o.last_error, 'provider', o.last_provider, 'steps', to_jsonb(o.steps))
        order by o.failed_at desc, o.id desc)
      from (select * from private.outbox
            where failed_at is not null and delivered_at is null and discarded_at is null
            order by failed_at desc, id desc
            limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)) o), '[]'),
    'total', (select count(*) from private.outbox
              where failed_at is not null and delivered_at is null and discarded_at is null),
    'waiting', (select count(*) from private.outbox
                where delivered_at is null and failed_at is null and discarded_at is null and waiting_for is not null),
    'circuits', (select jsonb_agg(jsonb_build_object('provider', provider, 'state', state, 'openedAt', opened_at,
                   'retryAt', retry_at, 'lastError', last_error) order by provider)
                 from private.provider_circuits));
end;
$$;

-- Replays failed events (one or up to 200): a fresh budget, attempts from zero, sent now. Steps already
-- done stay done, and pushes stay bound to the event's age, so a replay never sends a stale push.
create function public.admin_replay_events(p_actor text, p_ids bigint[], p_reason text default null)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  o private.outbox;
  v_count int := 0;
begin
  perform private.require_staff(p_actor, 'admin');
  if coalesce(cardinality(p_ids), 0) = 0 or cardinality(p_ids) > 200 then
    perform private.fail('invalid_ids', 'choose between 1 and 200 events');
  end if;
  for o in
    update private.outbox
      set failed_at = null, attempts = 0, waiting_for = null, replays = replays + 1, next_attempt_at = now(),
          deadline = now() + (private.outbox_policy(event)).retry_budget
      where id = any (p_ids) and failed_at is not null and delivered_at is null and discarded_at is null
      returning *
  loop
    perform private.audit(p_actor, 'events.replay', null, 'outbox:' || o.id, p_reason,
      jsonb_build_object('event', o.event, 'replays', o.replays));
    perform private.deliver(o.id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- Gives up on failed events for good, with the reason.
create function public.admin_discard_events(p_actor text, p_ids bigint[], p_reason text)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  o private.outbox;
  v_count int := 0;
begin
  perform private.require_staff(p_actor, 'admin');
  perform private.require_reason(p_reason);
  if coalesce(cardinality(p_ids), 0) = 0 or cardinality(p_ids) > 200 then
    perform private.fail('invalid_ids', 'choose between 1 and 200 events');
  end if;
  for o in
    update private.outbox
      set discarded_at = now(), discarded_by = lower(trim(p_actor)), discard_reason = left(trim(p_reason), 1000)
      where id = any (p_ids) and failed_at is not null and delivered_at is null and discarded_at is null
      returning *
  loop
    perform private.audit(p_actor, 'events.discard', null, 'outbox:' || o.id, p_reason,
      jsonb_build_object('event', o.event));
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

revoke execute on function public.admin_failed_events(text, int, int), public.admin_replay_events(text, bigint[], text),
  public.admin_discard_events(text, bigint[], text) from public, anon, authenticated;
grant execute on function public.admin_failed_events(text, int, int), public.admin_replay_events(text, bigint[], text),
  public.admin_discard_events(text, bigint[], text) to service_role;

-- sophros hears `events` on staff:queues when the dead-letter queue or a circuit changes (see
-- staff_live_events): the queue's name only, never an id or a payload.
create function private.staff_events_changed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_table_name = 'outbox' and not exists (
    select from changed_new n join changed_old o using (id)
    where n.failed_at is distinct from o.failed_at or n.discarded_at is distinct from o.discarded_at
      or (o.failed_at is not null and n.delivered_at is distinct from o.delivered_at)
  ) then
    return null;
  end if;
  perform realtime.send(jsonb_build_object('queue', 'events'), 'queue', 'staff:queues', true);
  return null;
exception when others then
  raise warning 'staff broadcast events failed: %', sqlerrm;
  return null;
end;
$$;

revoke all on function private.staff_events_changed() from public, anon, authenticated;

create trigger staff_live_events after update on private.outbox
  referencing old table as changed_old new table as changed_new
  for each statement execute function private.staff_events_changed();

create function private.staff_circuits_changed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select from changed_new n join changed_old o using (provider) where n.state is distinct from o.state) then
    perform realtime.send(jsonb_build_object('queue', 'events'), 'queue', 'staff:queues', true);
  end if;
  return null;
exception when others then
  raise warning 'staff broadcast circuits failed: %', sqlerrm;
  return null;
end;
$$;

revoke all on function private.staff_circuits_changed() from public, anon, authenticated;

create trigger staff_live_circuits after update on private.provider_circuits
  referencing old table as changed_old new table as changed_new
  for each statement execute function private.staff_circuits_changed();

-- MARK: Media verdicts

-- Rekognition's verdict on a new photo, in one transaction: the status and its flag together, so a
-- refusal is never left without the flag that puts it in front of the team. Only while still pending;
-- false when it was decided already.
create function public.apply_media_verdict(p_media uuid, p_verdict text, p_labels text[] default '{}')
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  m public.profile_media;
begin
  if p_verdict not in ('approved', 'rejected', 'review') then
    perform private.fail('invalid_verdict', 'approved, rejected or review');
  end if;
  select * into m from public.profile_media where id = p_media and status = 'pending' for update;
  if not found then
    return false;
  end if;
  if p_verdict <> 'review' then
    update public.profile_media set status = p_verdict::public.media_status where id = p_media;
  end if;
  -- 'review' leaves the photo pending: a retry must not flag it twice.
  if p_verdict <> 'approved' and not exists (
    select from public.media_flags f
    where f.context = 'profile' and f.key = m.key and f.reviewed_at is null
  ) then
    insert into public.media_flags (user_id, context, key, verdict, labels)
      values (m.user_id, 'profile', m.key, p_verdict, coalesce(p_labels, '{}'));
  end if;
  return true;
end;
$$;

revoke execute on function public.apply_media_verdict(uuid, text, text[]) from public, anon, authenticated;
grant execute on function public.apply_media_verdict(uuid, text, text[]) to service_role;
