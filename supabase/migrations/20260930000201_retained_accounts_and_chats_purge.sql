-- What is kept for members' safety goes after its time, outside the database too (Stream, R2, the selfies
-- bucket), as the privacy policy says:
--
--   account kept for safety          erased 1 year after its case is closed (below), like delete-account erases
--   (20260928000131)                 one: Stream user and messages, R2 media, selfies, Auth user and every row
--   chat of an ended match           erased 1 year after the match ended: the Stream channel (frozen by
--                                    match.ended) and the chat photos, videos and voice messages its messages
--                                    point to in R2, whoever sent them (u/<id>/chat/…)
--   chat kept at a deletion          the same, 1 year after the deletion ended it: delete-account keeps a chat
--   (decision 5.4)                   whose other member is on hold or banned, frozen
--   selfies of a banned account      erased 6 months after the ban, for an appeal; a lifted hold's still go at
--                                    once (selfie.delete)
--
-- A daily job, private.queue_retention_purges() (pg_cron `retention-purge-external`), queues one outbox event
-- per thing due, handled by db-events: `account.purge`, `chat.erase`, `selfie.expired`. Each handler asks the
-- database again whether it is still due (a hold or a report reopened since keeps the account) and records its
-- steps, so a retry repeats nothing. An event still undelivered is not queued twice; one that failed is
-- queued again a week later.
--
-- When the case of a kept account is closed (private.retained_case_closed_at): never while it is on hold
-- (review, selfie) or reported with a report still open. Otherwise at the latest of: its deletion, the last
-- change of its hold (the ban decided, or the hold lifted), the last report about it handled. A banned account
-- is closed from its ban (or its deletion, when later): 1 year on, it is erased; its ban's identity marks stay,
-- so the person still can't come back with the same email, phone or sign-in.
--
-- Chats are tracked in private.chat_retention from the moment they end, by match id: the match row goes with
-- an erased account, the Stream channel doesn't. Matches ended before this migration are tracked from their
-- `ended_at`; channels whose match row was already gone before it are not known and stay until their remaining
-- member's account is erased.

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

-- MARK: When things are due

-- When the case behind a kept account was closed, or null while it is still open (a hold in force, a report
-- still open) or the account isn't kept.
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
    and p.moderation is distinct from 'review' and p.moderation is distinct from 'selfie'
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
  select coalesce(private.retained_case_closed_at(p_user) < now() - interval '1 year', false);
$$;

-- db-events, before erasing a chat: it ended over a year ago and isn't erased yet.
create function public.chat_erase_due(p_match uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from private.chat_retention where match_id = p_match and ended_at < now() - interval '1 year');
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
  select coalesce(private.banned_since(p_user) < now() - interval '6 months', false)
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

-- Every day: what is due, up to 500 of each a day. Returns how many of each were queued.
create function private.queue_retention_purges()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
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
    perform private.emit('account.purge', jsonb_build_object('userId', v_id));
    v_accounts := v_accounts + 1;
  end loop;

  for v_id in
    select c.match_id from private.chat_retention c
    where c.ended_at < now() - interval '1 year'
      and not private.retention_queued('chat.erase', 'matchId', c.match_id::text)
    order by c.ended_at limit 500
  loop
    perform private.emit('chat.erase', jsonb_build_object('matchId', v_id));
    v_chats := v_chats + 1;
  end loop;

  for v_id in
    select distinct s.user_id from private.selfie_checks s
    where public.banned_selfies_due(s.user_id)
      and not private.retention_queued('selfie.expired', 'userId', s.user_id::text)
    limit 500
  loop
    perform private.emit('selfie.expired', jsonb_build_object('userId', v_id));
    v_selfies := v_selfies + 1;
  end loop;

  return jsonb_build_object('accounts', v_accounts, 'chats', v_chats, 'selfies', v_selfies);
end;
$$;

insert into private.outbox_policies (event, retry_budget, expires_after, push_ttl, providers) values
  ('account.purge', '24 hours', null, null, '{stream,r2}'),
  ('chat.erase', '24 hours', null, null, '{stream,r2}'),
  ('selfie.expired', '24 hours', null, null, '{}');

revoke all on function private.track_ended_chat(), private.retained_case_closed_at(uuid), private.banned_since(uuid),
  private.retention_queued(text, text, text), private.queue_retention_purges()
  from public, anon, authenticated;
revoke execute on function public.retained_account_due(uuid), public.chat_erase_due(uuid), public.chat_erased(uuid),
  public.banned_selfies_due(uuid) from public, anon, authenticated;
grant execute on function public.retained_account_due(uuid), public.chat_erase_due(uuid), public.chat_erased(uuid),
  public.banned_selfies_due(uuid) to service_role;

select cron.schedule('retention-purge-external', '23 4 * * *', 'select private.queue_retention_purges()');
