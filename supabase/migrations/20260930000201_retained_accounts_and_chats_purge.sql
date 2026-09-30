-- What is kept for members' safety goes after its time, outside the database too (Stream, R2, the selfies
-- bucket), as the privacy policy says:
--
--   account kept for safety          erased 1 year after its case is closed (below), like delete-account erases
--   (20260928000131)                 one: its chats, Stream user, R2 media, selfies, then its Auth user and rows
--   chat of an ended match           erased 1 year after the match ended: the chat photos, videos and voice
--                                    messages its messages point to in R2 (each sender's own, u/<id>/chat/…),
--                                    then the Stream channel (frozen by match.ended)
--   chat kept at a deletion          the same, 1 year after the deletion ended it: delete-account keeps a chat
--   (decision 5.4)                   whose other member is on hold or banned, frozen
--   selfies of a banned account      erased 6 months after the ban, for an appeal; a lifted hold's still go at
--                                    once (selfie.delete)
--
-- A daily job, private.queue_retention_purges() (pg_cron `retention-purge-external`, watched like the other
-- daily jobs, 20260930000101), queues one outbox event per thing due, handled by db-events: `account.purge`,
-- `chat.erase`, `selfie.expired`, spread a second apart so a backlog doesn't hit Stream at once. Each handler
-- asks the database again whether it is still due (a hold or a report reopened since keeps the account) and
-- records its steps, so a retry repeats nothing. An event on its way is not queued again, nor one queued in the
-- last week (a failed one is queued again a week after it was first queued). All are erasures: a failed one
-- waits for the team, never dropped.
--
-- When the case of a kept account is closed (private.retained_case_closed_at): only while it is banned or its
-- hold is lifted, and no report about it is still open. Then at the latest of: its deletion, the last change
-- of its hold (the ban decided, or the hold lifted), the last report about it handled. A kept banned account
-- is erased a year after that; its ban stays remembered (private.banned_accounts) and its ban's identity marks
-- stay, so the person still can't come back with the same email, phone or sign-in.
--
-- A banned account's moderation history outlives it: its moderation log, staff notes, account links and photo
-- flags are no longer deleted with the profile (the foreign keys go, a trigger does the cascade for any other
-- account), and privacy-purge keeps them their 3 years.
--
-- Chats are tracked in private.chat_retention from the moment they end, by match id, since a chat kept at a
-- deletion (decision 5.4) outlives its match row. Matches ended before this migration are tracked from their
-- `ended_at`. Channels frozen before it whose match row is already gone are found once in Stream (`chat.sweep`)
-- and tracked from their last update.
--
-- migration-guard: allow destructive drop - the moderation history's foreign keys, replaced by a trigger that
-- keeps a banned account's

-- MARK: Periods

-- 20260930000101, plus the periods of what db-events erases.
create or replace function private.retention_period(p_data text, p_banned boolean default false)
returns interval
language plpgsql
immutable
set search_path = ''
as $$
begin
  case p_data
    -- Moderation log, staff notes, photo flags, account links, team access log.
    when 'moderation' then return case when p_banned then interval '3 years' else interval '1 year' end;
    -- Identity marks and digests, from the account's deletion.
    when 'identity' then return case when p_banned then interval '3 years' else interval '1 year' end;
    -- The ban itself, from the account's erasure.
    when 'ban' then return interval '3 years';
    when 'report' then return interval '1 year';
    when 'support' then return interval '3 years';
    when 'purchase' then return interval '10 years';
    -- An account kept for safety, from its case's closing.
    when 'kept_account' then return interval '1 year';
    -- A chat, from its end.
    when 'chat' then return interval '1 year';
    -- A banned account's selfies, from the ban.
    when 'banned_selfies' then return interval '6 months';
    -- Outbox: delivered rows, and dropped, discarded or failed ones.
    when 'outbox_delivered' then return interval '7 days';
    when 'outbox_dead' then return interval '30 days';
    when 'job_runs' then return interval '90 days';
    else
      -- An unknown name would compare as null and delete nothing, silently.
      raise exception 'unknown retention period %', p_data;
  end case;
end;
$$;

-- MARK: A banned account's history outlives it

alter table private.moderation_log drop constraint moderation_log_user_id_fkey;
alter table private.staff_notes drop constraint staff_notes_user_id_fkey;
alter table private.account_links drop constraint account_links_user_id_fkey,
  drop constraint account_links_deleted_user_id_fkey;
alter table public.media_flags drop constraint media_flags_user_id_fkey;

-- What the foreign keys did, for any account but a banned one.
create function private.on_profile_erased()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.moderation = 'banned' then
    return null;
  end if;
  delete from private.moderation_log where user_id = old.id;
  delete from private.staff_notes where user_id = old.id;
  delete from private.account_links where old.id in (user_id, deleted_user_id);
  update public.media_flags set user_id = null where user_id = old.id;
  return null;
end;
$$;

create trigger profiles_history_erased after delete on public.profiles
  for each row execute function private.on_profile_erased();

-- MARK: Chats that ended

create table private.chat_retention (
  match_id uuid primary key,
  -- The match ended (unmatch, block, report, ban, a kept account), or an account in it was erased.
  ended_at timestamptz not null
);

create index chat_retention_ended_idx on private.chat_retention (ended_at);

insert into private.chat_retention (match_id, ended_at)
  select id, ended_at from public.matches where ended_at is not null;

create function private.track_ended_chat()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    insert into private.chat_retention (match_id, ended_at) values (old.id, coalesce(old.ended_at, now()))
      on conflict (match_id) do nothing;
    return null;
  end if;
  insert into private.chat_retention (match_id, ended_at) values (new.id, new.ended_at)
    on conflict (match_id) do nothing;
  return null;
end;
$$;

create trigger matches_chat_ended after update of ended_at on public.matches
  for each row when (old.ended_at is null and new.ended_at is not null) execute function private.track_ended_chat();
create trigger matches_chat_erased after delete on public.matches
  for each row execute function private.track_ended_chat();

-- db-events `chat.sweep`, once: frozen channels Stream still has, found by id with the date of their last
-- update. Those whose match row is gone (kept at a deletion before this migration) are tracked from that date;
-- the others are tracked already. Returns how many it added.
create function public.track_frozen_chats(p_chats jsonb)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count int;
begin
  insert into private.chat_retention (match_id, ended_at)
    select c.id, least(c.at, now())
    from jsonb_to_recordset(coalesce(p_chats, '[]')) as c(id uuid, at timestamptz)
    where c.id is not null and c.at is not null
      and not exists (select 1 from public.matches m where m.id = c.id)
    on conflict (match_id) do nothing;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- MARK: When things are due

-- When the case behind a kept account was closed, or null while it is still open (a hold in force, a report
-- still open) or the account isn't kept. Closed only in the states known to close it: banned, or no hold.
create function private.retained_case_closed_at(p_user uuid)
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select greatest(p.deleted_at,
      (select max(l.created_at) from private.moderation_log l where l.user_id = p.id),
      (select max(r.handled_at) from public.reports r where r.reported = p.id))
  from public.profiles p
  where p.id = p_user and p.deleted_at is not null
    and (p.moderation is null or p.moderation = 'banned')
    and not exists (select 1 from public.reports r where r.reported = p.id and r.handled_at is null);
$$;

-- db-events (service role), before erasing a kept account: its case closed over a year ago.
create function public.retained_account_due(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(private.retained_case_closed_at(p_user) < now() - private.retention_period('kept_account'), false);
$$;

-- db-events, before erasing a chat: it ended over a year ago and isn't erased yet.
create function public.chat_erase_due(p_match uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from private.chat_retention
    where match_id = p_match and ended_at < now() - private.retention_period('chat'));
$$;

-- db-events, once a chat is erased (on its own, or with a kept account): nothing left to track.
create function public.chat_erased(p_match uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from private.chat_retention where match_id = p_match;
$$;

-- When the account was banned: its latest hold change, the ban in force.
create function private.banned_since(p_user uuid)
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select (select max(l.created_at) from private.moderation_log l where l.user_id = p.id)
  from public.profiles p where p.id = p_user and p.moderation = 'banned';
$$;

-- db-events, before erasing a banned account's selfies: banned over 6 months ago, selfies still there.
create function public.banned_selfies_due(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(private.banned_since(p_user) < now() - private.retention_period('banned_selfies'), false)
    and exists (select 1 from private.selfie_checks where user_id = p_user);
$$;

-- MARK: Queueing

-- An event about this subject still on its way, or queued in the last week: not queued again yet.
create function private.retention_queued(p_event text, p_key text, p_value text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from private.outbox
    where event = p_event and payload ->> p_key = p_value
      and (created_at > now() - interval '7 days' or (delivered_at is null and failed_at is null and discarded_at is null)));
$$;

-- One event, posted by the outbox's retry loop at `p_at` rather than at once.
create function private.emit_at(p_event text, p_payload jsonb, p_at timestamptz)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into private.outbox (event, payload, next_attempt_at) values (p_event, p_payload, p_at);
$$;

-- Every day: what is due, up to 500 of each, a second apart. Records and returns how many of each were queued.
create function private.queue_retention_purges()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run bigint := private.start_job('retention-purge-external');
  v_id uuid;
  v_n int := 0;
  v_accounts int := 0;
  v_chats int := 0;
  v_selfies int := 0;
begin
  for v_id in
    select p.id from public.profiles p
    where p.deleted_at is not null and public.retained_account_due(p.id)
      and not private.retention_queued('account.purge', 'userId', p.id::text)
    order by p.deleted_at limit 500
  loop
    perform private.emit_at('account.purge', jsonb_build_object('userId', v_id), now() + v_n * interval '1 second');
    v_n := v_n + 1;
    v_accounts := v_accounts + 1;
  end loop;

  for v_id in
    select c.match_id from private.chat_retention c
    where c.ended_at < now() - private.retention_period('chat')
      and not private.retention_queued('chat.erase', 'matchId', c.match_id::text)
    order by c.ended_at limit 500
  loop
    perform private.emit_at('chat.erase', jsonb_build_object('matchId', v_id), now() + v_n * interval '1 second');
    v_n := v_n + 1;
    v_chats := v_chats + 1;
  end loop;

  for v_id in
    select distinct s.user_id from private.selfie_checks s
    where public.banned_selfies_due(s.user_id)
      and not private.retention_queued('selfie.expired', 'userId', s.user_id::text)
    limit 500
  loop
    perform private.emit_at('selfie.expired', jsonb_build_object('userId', v_id), now() + v_n * interval '1 second');
    v_n := v_n + 1;
    v_selfies := v_selfies + 1;
  end loop;

  return private.finish_job(v_run, jsonb_build_object('accounts', v_accounts, 'chats', v_chats, 'selfies', v_selfies));
end;
$$;

insert into private.outbox_policies (event, retry_budget, expires_after, push_ttl, providers, erasure) values
  ('account.purge', '24 hours', null, null, '{stream,r2}', true),
  ('chat.erase', '24 hours', null, null, '{stream,r2}', true),
  ('selfie.expired', '24 hours', null, null, '{}', true),
  ('chat.sweep', '24 hours', null, null, '{stream}', true);

insert into private.watched_jobs (job) values ('retention-purge-external');

revoke all on function private.on_profile_erased(), private.track_ended_chat(), private.retained_case_closed_at(uuid),
  private.banned_since(uuid), private.retention_queued(text, text, text), private.emit_at(text, jsonb, timestamptz),
  private.queue_retention_purges()
  from public, anon, authenticated;
revoke execute on function public.retained_account_due(uuid), public.chat_erase_due(uuid), public.chat_erased(uuid),
  public.banned_selfies_due(uuid), public.track_frozen_chats(jsonb) from public, anon, authenticated;
grant execute on function public.retained_account_due(uuid), public.chat_erase_due(uuid), public.chat_erased(uuid),
  public.banned_selfies_due(uuid), public.track_frozen_chats(jsonb) to service_role;

select cron.schedule('retention-purge-external', '23 4 * * *', 'select private.queue_retention_purges()');

-- The sweep, once, ten minutes from now: the Edge Functions deploy right after the migrations, and db-events
-- acknowledges an event it doesn't know.
select private.emit_at('chat.sweep', '{}', now() + interval '10 minutes');
