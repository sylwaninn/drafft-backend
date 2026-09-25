-- Events leave the database two ways:
--
-- 1. Realtime Broadcast to `user:<id>` topics, for the open app (new like, match, session change,
--    photo approved). Fire-and-forget: the app refetches on reconnect anyway.
-- 2. An outbox for side effects that must happen (chat channel creation, push, moderation, media
--    cleanup). Rows are written in the same transaction as the change, posted to the db-events Edge
--    Function via pg_net after commit, and retried with backoff by pg_cron until acknowledged.
--    Handlers are idempotent, so a retry after a lost ack is harmless.

-- MARK: Push tokens

create table public.push_tokens (
  token text primary key check (char_length(token) <= 200),
  user_id uuid not null references public.profiles (id) on delete cascade,
  environment text not null check (environment in ('sandbox', 'production')),
  updated_at timestamptz not null default now()
);

create index push_tokens_user_idx on public.push_tokens (user_id);

alter table public.push_tokens enable row level security;

-- A device token moves to whoever signed in last on that device.
create function public.register_push_token(p_token text, p_environment text)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.push_tokens (token, user_id, environment)
  values (p_token, (select auth.uid()), p_environment)
  on conflict (token) do update
    set user_id = excluded.user_id, environment = excluded.environment, updated_at = now();
$$;

create function public.unregister_push_token(p_token text)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.push_tokens where token = p_token and user_id = (select auth.uid());
$$;

grant execute on function public.register_push_token(text, text), public.unregister_push_token(text) to authenticated;

-- MARK: Realtime

-- Each person listens on their own private topic only.
create policy user_topic_receive on realtime.messages for select to authenticated
  using (
    realtime.messages.extension = 'broadcast'
    and realtime.topic() = 'user:' || (select auth.uid())::text
  );

create function private.broadcast(p_user uuid, p_event text, p_payload jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform realtime.send(p_payload, p_event, 'user:' || p_user::text, true);
exception when others then
  -- Realtime is a nicety: never fail the write because of it.
  raise warning 'broadcast % to % failed: %', p_event, p_user, sqlerrm;
end;
$$;

-- MARK: Outbox

create table private.outbox (
  id bigint generated always as identity primary key,
  event text not null,
  payload jsonb not null,
  attempts int not null default 0,
  last_attempt_at timestamptz,
  delivered_at timestamptz,
  created_at timestamptz not null default now()
);

create index outbox_pending_idx on private.outbox (id) where delivered_at is null;

-- Posts one outbox row to the db-events function. The URL and shared secret come from Vault
-- (`edge_functions_url`, `db_events_secret`), so no environment-specific value lives in migrations.
create function private.deliver(p_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
  v_secret text;
  o private.outbox;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'edge_functions_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'db_events_secret';
  if v_url is null or v_secret is null then
    raise warning 'outbox %: vault secrets edge_functions_url / db_events_secret missing', p_id;
    return;
  end if;
  update private.outbox set attempts = attempts + 1, last_attempt_at = now()
    where id = p_id and delivered_at is null
    returning * into o;
  if o.id is null then
    return;
  end if;
  perform net.http_post(
    url := v_url || '/db-events',
    body := jsonb_build_object('id', o.id, 'event', o.event, 'payload', o.payload),
    headers := jsonb_build_object('content-type', 'application/json', 'x-webhook-secret', v_secret),
    timeout_milliseconds := 10000);
end;
$$;

create function private.emit(p_event text, p_payload jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
begin
  insert into private.outbox (event, payload) values (p_event, p_payload) returning id into v_id;
  perform private.deliver(v_id);
end;
$$;

-- Called by db-events once an event is fully handled.
create function public.ack_event(p_id bigint)
returns void
language sql
security definer
set search_path = ''
as $$
  update private.outbox set delivered_at = now() where id = p_id and delivered_at is null;
$$;

revoke execute on function public.ack_event(bigint) from public, anon, authenticated;
grant execute on function public.ack_event(bigint) to service_role;

-- Backoff: 1, 2, 4, 8... minutes, up to 10 attempts. Rows that still fail stay for inspection.
create function private.retry_outbox()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
begin
  for v_id in
    select id from private.outbox
    where delivered_at is null
      and attempts < 10
      and coalesce(last_attempt_at, created_at) < now() - make_interval(mins => power(2, greatest(attempts - 1, 0))::int)
    order by id
    limit 500
  loop
    perform private.deliver(v_id);
  end loop;
end;
$$;

select cron.schedule('outbox-retry', '* * * * *', 'select private.retry_outbox()');
select cron.schedule('outbox-cleanup', '17 3 * * *',
  $$delete from private.outbox where delivered_at < now() - interval '7 days'$$);

-- MARK: Triggers

create function private.on_swipe()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.action <> 'pass' then
    perform private.broadcast(new.target, 'like', jsonb_build_object('from', new.swiper, 'superLike', new.action = 'superlike'));
    perform private.emit('like.received', jsonb_build_object(
      'from', new.swiper, 'to', new.target, 'superLike', new.action = 'superlike'));
  end if;
  return null;
end;
$$;

create trigger swipes_events after insert on public.swipes
  for each row execute function private.on_swipe();

create function private.on_match()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    perform private.broadcast(new.user_a, 'match', jsonb_build_object('matchId', new.id, 'with', new.user_b));
    perform private.broadcast(new.user_b, 'match', jsonb_build_object('matchId', new.id, 'with', new.user_a));
    perform private.emit('match.created', jsonb_build_object('matchId', new.id, 'userA', new.user_a, 'userB', new.user_b));
  elsif new.ended_at is not null and old.ended_at is null then
    -- Same event for unmatch and block: the other person can't tell which.
    perform private.broadcast(new.user_a, 'match_ended', jsonb_build_object('matchId', new.id));
    perform private.broadcast(new.user_b, 'match_ended', jsonb_build_object('matchId', new.id));
    perform private.emit('match.ended', jsonb_build_object('matchId', new.id));
  end if;
  return null;
end;
$$;

create trigger matches_events after insert or update of ended_at on public.matches
  for each row execute function private.on_match();

create function private.on_session()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  m public.matches;
  v_payload jsonb;
begin
  if tg_op = 'UPDATE' and new.status = old.status then
    return null;
  end if;
  select * into m from public.matches where id = new.match_id;
  v_payload := jsonb_build_object(
    'sessionId', new.id, 'matchId', new.match_id, 'status', new.status,
    'proposerId', new.proposer_id, 'actorId', coalesce((select auth.uid()), new.proposer_id),
    'replacesId', new.replaces_id);
  perform private.broadcast(m.user_a, 'session', v_payload);
  perform private.broadcast(m.user_b, 'session', v_payload);
  -- `countered` is followed by the insert of the new proposal, which carries the event.
  if new.status <> 'countered' then
    perform private.emit('session.' || case when tg_op = 'INSERT' then 'proposed' else new.status::text end, v_payload);
  end if;
  return null;
end;
$$;

create trigger sessions_events after insert or update of status on public.sessions
  for each row execute function private.on_session();

create function private.on_media()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    perform private.emit('media.created', jsonb_build_object(
      'mediaId', new.id, 'userId', new.user_id, 'kind', new.kind, 'key', new.key, 'posterKey', new.poster_key));
  elsif tg_op = 'DELETE' then
    perform private.emit('media.deleted', jsonb_build_object(
      'keys', to_jsonb(array_remove(array[old.key, old.poster_key], null))));
  elsif new.status <> old.status then
    perform private.broadcast(new.user_id, 'media', jsonb_build_object('mediaId', new.id, 'status', new.status));
  end if;
  return null;
end;
$$;

create trigger profile_media_events after insert or delete or update of status on public.profile_media
  for each row execute function private.on_media();
