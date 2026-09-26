-- A paused profile is frozen: hidden from others, and its owner can't act until they resume.
--
-- While paused, the owner can't swipe, undo, boost, browse Discover (20260926000002), propose or
-- answer sessions, or write in chats (a Stream ban, applied by db-events on `profile.paused`). They can
-- still read, edit their profile, block, report, unmatch, and resume. Others can't swipe on them, and
-- their pending likes leave the Likes tab. The app greys its screens out on `paused` errors.

create function private.require_unpaused(p_user uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.profiles where id = p_user and paused) then
    perform private.fail('paused', 'your profile is paused, resume it first');
  end if;
end;
$$;

-- Swipes: at the table, so every path is covered. A paused target looks like any unavailable profile.
create function private.swipe_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_unpaused(new.swiper);
  if exists (select 1 from public.profiles where id = new.target and paused) then
    perform private.fail('not_found', 'profile not available');
  end if;
  return new;
end;
$$;

create trigger swipes_pause_guard before insert on public.swipes
  for each row execute function private.swipe_guard();

-- Sessions: whoever acts (propose, counter, accept, decline, cancel) must not be paused. Server-side
-- writes (no auth.uid()) are not concerned.
create function private.session_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_unpaused((select auth.uid()));
  return new;
end;
$$;

create trigger sessions_pause_guard before insert or update on public.sessions
  for each row execute function private.session_guard();

-- Undo: same as before, refused while paused.
create or replace function public.undo_last_swipe()
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  s public.swipes;
begin
  perform private.require_unpaused(v_me);
  select * into s from public.swipes where swiper = v_me order by created_at desc limit 1;
  if s.target is null
     or s.created_at < now() - interval '10 minutes'
     or exists (select 1 from public.matches where user_a = least(v_me, s.target) and user_b = greatest(v_me, s.target)) then
    perform private.fail('cannot_undo', 'nothing to undo');
  end if;
  delete from public.swipes where swiper = v_me and target = s.target;
  if s.action = 'superlike' then
    update public.wallets set super_likes = super_likes + 1 where user_id = v_me;
  end if;
  return s.target;
end;
$$;

-- Likes: paused people's likes wait, hidden, until they resume.
create or replace function public.liked_me(p_limit int default 50, p_before timestamptz default null)
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select c.card || jsonb_build_object(
      'age', private.age_of(p.birthdate),
      'superLikedMe', s.action = 'superlike',
      'superLikeNote', s.note,
      'opener', s.opener,
      'likedAt', s.created_at,
      'cardVersion', c.version)
  from public.swipes s
  join public.profiles p on p.id = s.swiper
  join public.profile_cards c on c.user_id = s.swiper
  where s.target = (select auth.uid())
    and s.action <> 'pass'
    and (p_before is null or s.created_at < p_before)
    and p.onboarded_at is not null
    and not p.paused
    and not exists (select 1 from public.swipes r where r.swiper = s.target and r.target = s.swiper)
    and not private.blocked_between(s.swiper, s.target)
  order by (s.action = 'superlike') desc, s.created_at desc
  limit least(greatest(p_limit, 1), 100);
$$;

-- Chats: db-events reads the current state and bans or unbans the person in Stream.
create function private.on_paused()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.paused is distinct from old.paused then
    perform private.emit('profile.paused', jsonb_build_object('userId', new.id, 'paused', new.paused));
  end if;
  return null;
end;
$$;

create trigger profiles_paused after update of paused on public.profiles
  for each row execute function private.on_paused();
