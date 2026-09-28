-- Upcoming sessions (`pending` or `accepted`, not yet passed) no longer outlive the match or the account
-- behind them. Before, an unmatch, a block, a ban or a deleted account left an accepted session in place:
-- nobody could cancel it any more (cancel_session needs an active match) and the reminders still went off.
--
-- - The match ends (unmatch, block, report): its upcoming sessions are cancelled. Both apps get the
--   `session` broadcast (Realtime), next to `match_ended`, and drop them; no push and no chat message
--   (on_session emits nothing for an ended match): the chat is deleted anyway, a push naming the person
--   would tell a blocked person who blocked them, and it would come on top of the match disappearing.
-- - An account is banned: its upcoming sessions are cancelled, with the usual `session.cancelled` event,
--   in its name (drafft.session_actor): the other person gets the push and the chat card, like for any
--   cancellation, so nobody goes to meet a banned account. The ban itself isn't revealed. A `review` or
--   `selfie` hold is lifted most of the time: sessions stay.
-- - An account is deleted: its sessions go with its matches (cascade). They're cancelled just before, so
--   the other person's open app hears the `session` broadcast; no event (there'd be nothing left to read).
--
-- Only upcoming ones: a session that has passed keeps its status (history). "Passed" is the same as the
-- Sessions tab (upcoming_sessions): the chosen time, or the last option, more than 2 hours ago.

-- Who acted (drafft.session_actor, for the ban: the banned account) and whether to leave db-events out
-- (drafft.session_quiet, for a deletion). An ended match never gets a session event: no chat, no push.
create or replace function private.on_session()
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
    'proposerId', new.proposer_id,
    'actorId', coalesce(nullif(current_setting('drafft.session_actor', true), '')::uuid, (select auth.uid()),
      new.proposer_id),
    'replacesId', new.replaces_id);
  perform private.broadcast(m.user_a, 'session', v_payload);
  perform private.broadcast(m.user_b, 'session', v_payload);
  -- `countered` is followed by the insert of the new proposal, which carries the event.
  if new.status <> 'countered' and m.ended_at is null
     and coalesce(current_setting('drafft.session_quiet', true), '') <> 'on' then
    perform private.emit('session.' || case when tg_op = 'INSERT' then 'proposed' else new.status::text end, v_payload);
  end if;
  return null;
end;
$$;

-- Cancels the upcoming sessions of one match (p_match) or of every match of one person (p_user).
create function private.cancel_upcoming_sessions(p_match uuid, p_user uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.sessions s set status = 'cancelled'
  from public.matches m
  where m.id = s.match_id
    and (m.id = p_match or p_user in (m.user_a, m.user_b))
    and s.status in ('pending', 'accepted')
    and coalesce(s.chosen_at, s.options[cardinality(s.options)]) > now() - interval '2 hours';
$$;

create function private.on_match_end_sessions()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.ended_at is not null and old.ended_at is null then
    perform private.cancel_upcoming_sessions(new.id, null);
  end if;
  return null;
end;
$$;

create trigger matches_end_sessions after update of ended_at on public.matches
  for each row execute function private.on_match_end_sessions();

create function private.on_ban_sessions()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.moderation = 'banned' and old.moderation is distinct from 'banned' then
    perform set_config('drafft.session_actor', new.id::text, true);
    perform private.cancel_upcoming_sessions(null, new.id);
    perform set_config('drafft.session_actor', '', true);
  end if;
  return null;
end;
$$;

create trigger profiles_ban_sessions after update of moderation on public.profiles
  for each row execute function private.on_ban_sessions();

create function private.on_profile_delete_sessions()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform set_config('drafft.session_quiet', 'on', true);
  perform private.cancel_upcoming_sessions(null, old.id);
  perform set_config('drafft.session_quiet', '', true);
  return old;
end;
$$;

create trigger profiles_delete_sessions before delete on public.profiles
  for each row execute function private.on_profile_delete_sessions();

revoke execute on function private.cancel_upcoming_sessions(uuid, uuid), private.on_match_end_sessions(),
  private.on_ban_sessions(), private.on_profile_delete_sessions() from public, anon, authenticated;
