-- Revoked sessions end at once. When Auth sessions are deleted (sophros "Sign out everywhere" through
-- admin_revoke_sessions, a sign-out from another device with the global or others scope, the account
-- deleted), the database broadcasts `session_revoked` on each person's `user:<id>` topic with the ids of
-- the sessions that ended. An app whose own session (the `session_id` claim of its token) is in the list
-- signs out right away, instead of when its access token expires. A normal sign-out also deletes its own
-- session: that device is signing out anyway, and the others aren't in the list.
create function private.broadcast_session_revoked()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
begin
  for r in select s.user_id, jsonb_agg(s.id) as ids from old_sessions s group by s.user_id loop
    -- private.broadcast never fails the delete (Realtime is best effort; the refresh token is gone anyway).
    perform private.broadcast(r.user_id, 'session_revoked', jsonb_build_object('sessions', r.ids));
  end loop;
  return null;
end;
$$;

revoke all on function private.broadcast_session_revoked() from public;

create trigger on_auth_sessions_deleted after delete on auth.sessions
  referencing old table as old_sessions
  for each statement execute function private.broadcast_session_revoked();
