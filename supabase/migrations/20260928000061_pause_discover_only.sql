-- A voluntary pause now only freezes discovery (product decision, supersedes 20260926000001 for
-- sessions and chats). While paused, the owner can't swipe, undo, boost or browse Discover, and stays
-- hidden from others: all unchanged, through private.require_unpaused. They keep planning sessions
-- with their current matches (propose, counter, accept, decline, cancel), and db-events no longer bans
-- them in Stream for a pause: chats stay writable.
--
-- Holds set by the team (`moderation` review, selfie, banned) keep freezing everything: sessions are
-- still refused with `moderated` here, and db-events keeps chats read-only while a hold is on.

create function private.require_unheld(p_user uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.profiles where id = p_user and moderation is not null) then
    perform private.fail('moderated', 'your account is on hold');
  end if;
end;
$$;

revoke all on function private.require_unheld(uuid) from public, anon, authenticated;

-- Sessions: whoever acts must not be on hold; a pause no longer matters. Server-side writes (no
-- auth.uid()) are not concerned. The trigger keeps its name (sessions_pause_guard).
create or replace function private.session_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_unheld((select auth.uid()));
  return new;
end;
$$;
