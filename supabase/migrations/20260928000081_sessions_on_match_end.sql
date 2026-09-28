-- Upcoming sessions (`pending` or `accepted`, not yet passed) no longer outlive the match or the account
-- behind them. Before, an unmatch, a block, a ban or a deleted account left an accepted session in place:
-- nobody could cancel it any more (cancel_session needs an active match) and the reminders still went off.
--
-- When the match ends (unmatch, block, report), an account is banned or an account is deleted, its
-- upcoming sessions are cancelled. Both apps get the `session` broadcast (Realtime) and drop them. The
-- other person always gets a push, `session.auto_cancelled`: the same neutral sentence in every case
-- ("Your session on Tuesday at 7:00 was cancelled."), no name and no reason, so a block or a ban isn't
-- revealed. The payload carries everything the push needs (language, time zone, setting), so db-events
-- never reads an account that a deletion has removed since. The chat card is only posted when the chat
-- still exists (a ban); an ended match's channel is deleted. The usual `session.cancelled` event (push
-- naming the person) is left out for all of these.
--
-- Only upcoming ones: a session that has passed keeps its status (history). "Passed" is the same as the
-- Sessions tab (upcoming_sessions): the chosen time, or the last option, more than 2 hours ago.

-- Who acted (drafft.session_actor, for the ban: the banned account) and whether to leave the usual event
-- out (drafft.session_quiet, set by cancel_upcoming_sessions, which emits session.auto_cancelled instead).
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

-- Cancels the upcoming sessions of one match (p_match) or of every match of one person (p_user), quietly
-- (no session.cancelled), and tells each participant other than p_actor with `session.auto_cancelled`,
-- with a chat card from p_user when p_chat (a ban: the chat stays; a deletion takes the chat with it).
-- A session only moves to `cancelled` once, so each push is emitted once.
create function private.cancel_upcoming_sessions(p_match uuid, p_user uuid, p_actor uuid, p_chat boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_to uuid;
  v_prof public.profiles;
begin
  perform set_config('drafft.session_quiet', 'on', true);
  for r in
    update public.sessions s set status = 'cancelled'
    from public.matches m
    where m.id = s.match_id
      and (m.id = p_match or p_user in (m.user_a, m.user_b))
      and s.status in ('pending', 'accepted')
      and coalesce(s.chosen_at, s.options[cardinality(s.options)]) > now() - interval '2 hours'
    returning s.id, s.match_id, m.user_a, m.user_b, m.ended_at,
      coalesce(s.chosen_at, case when cardinality(s.options) = 1 then s.options[1] end) as at
  loop
    foreach v_to in array array[r.user_a, r.user_b] loop
      continue when v_to is not distinct from p_actor or v_to = p_user;
      select * into v_prof from public.profiles where id = v_to;
      continue when not found;
      perform private.emit('session.auto_cancelled', jsonb_build_object(
        'sessionId', r.id, 'matchId', r.match_id, 'to', v_to, 'at', r.at,
        'language', v_prof.language, 'notify', v_prof.notify_messages,
        'timezone', coalesce((select nullif(d.timezone, '') from private.devices d
          where d.user_id = v_to and d.timezone <> '' order by d.last_seen_at desc limit 1), 'UTC'),
        'chatFrom', case when p_chat and r.ended_at is null then p_user end));
    end loop;
  end loop;
  perform set_config('drafft.session_quiet', '', true);
end;
$$;

create function private.on_match_end_sessions()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.ended_at is not null and old.ended_at is null then
    perform private.cancel_upcoming_sessions(new.id, null, (select auth.uid()), false);
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
    perform private.cancel_upcoming_sessions(null, new.id, new.id, true);
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
  -- Before the cascade: the events carry what db-events needs, it never reads this account again.
  perform private.cancel_upcoming_sessions(null, old.id, old.id, false);
  return old;
end;
$$;

create trigger profiles_delete_sessions before delete on public.profiles
  for each row execute function private.on_profile_delete_sessions();

revoke execute on function private.cancel_upcoming_sessions(uuid, uuid, uuid, boolean), private.on_match_end_sessions(),
  private.on_ban_sessions(), private.on_profile_delete_sessions() from public, anon, authenticated;
