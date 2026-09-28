-- Who liked you (decision 5.5): blurred for a free account, visible with drafft tempo, enforced here.
--
-- liked_me gives a free account, for each like, only an opaque handle, whether it was a super like,
-- when, and the ThumbHash of the first photo of the liker's card (a ~25-byte blurred preview). No
-- profile id, name, age, media key or URL. With drafft tempo (wallets.premium_until > now()) the
-- answer is the full card, as before.
--
-- The other ways to that identity are closed too:
--   - get_cards returns someone who liked you only to drafft tempo (it still returns people you
--     swiped yourself, i.e. cards Discover already showed you, and your matches);
--   - the `like` Realtime event no longer carries the liker's id (the app only needs to read
--     liked_me again).
-- Discover still pins super likes to the top of the deck with their star: that is what a super like
-- buys, for every account.
--
-- The handle is HMAC-SHA256(swiper || target) under a random key that never leaves the database: stable
-- for the app (lists, animations), not linkable to a profile id even by someone who knows candidate
-- ids, and different for each pair.

-- MARK: Opaque handle

create table private.like_handle_key (
  only_row boolean primary key default true check (only_row),
  key bytea not null default extensions.gen_random_bytes(32)
);
insert into private.like_handle_key default values;
revoke all on table private.like_handle_key from public, anon, authenticated;

create function private.like_handle(p_swiper uuid, p_target uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select encode(extensions.hmac(convert_to(p_swiper::text || ':' || p_target::text, 'UTF8'), k.key, 'sha256'), 'hex')
  from private.like_handle_key k;
$$;

revoke all on function private.like_handle(uuid, uuid) from public, anon, authenticated;

-- MARK: Likes

-- As in 20260928000141, plus: no soft-deleted liker (20260928000131), and the blurred shape without
-- drafft tempo. Premium is read once per call.
create or replace function public.liked_me(p_limit int default 50, p_before timestamptz default null)
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case when v.premium
    then private.sign_card(c.card, private.media_visible(s.swiper, s.target)) || jsonb_build_object(
      'age', private.age_of(p.birthdate),
      'superLikedMe', s.action = 'superlike',
      'superLikeNote', s.note,
      'opener', s.opener,
      'likedAt', s.created_at,
      'cardVersion', c.version)
    else jsonb_build_object(
      'likeId', private.like_handle(s.swiper, s.target),
      'superLike', s.action = 'superlike',
      'likedAt', s.created_at,
      'thumbhash', (select m ->> 'thumbhash'
                    from jsonb_array_elements(coalesce(c.card -> 'media', '[]'::jsonb)) with ordinality as t(m, i)
                    where m ->> 'kind' = 'photo'
                    order by i
                    limit 1))
    end
  from (select (select auth.uid()) as me, private.is_premium((select auth.uid())) as premium) v
  join public.swipes s on s.target = v.me
  join public.profiles p on p.id = s.swiper
  join public.profile_cards c on c.user_id = s.swiper
  where s.action <> 'pass'
    and (p_before is null or s.created_at < p_before)
    and p.onboarded_at is not null
    and p.deleted_at is null
    and not p.paused
    and not exists (select 1 from public.swipes r where r.swiper = s.target and r.target = s.swiper)
    and not private.blocked_between(s.swiper, s.target)
  order by (s.action = 'superlike') desc, s.created_at desc
  limit least(greatest(p_limit, 1), 100);
$$;

-- MARK: Cards by id

-- As in 20260928000141, but someone who liked you is returned only with drafft tempo: otherwise a card
-- is yours to read only once you swiped it (Discover showed it) or matched.
create or replace function public.get_cards(p_ids uuid[], p_known jsonb default '{}')
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select private.sign_card(c.card, private.media_visible(i.id, (select auth.uid())))
    || jsonb_build_object('age', private.age_of(p.birthdate), 'cardVersion', c.version)
  from unnest(p_ids[1:100]) as i(id)
  join public.profiles p on p.id = i.id
  join public.profile_cards c on c.user_id = i.id
  where c.version > coalesce((p_known ->> i.id::text)::bigint, 0)
    and p.deleted_at is null
    and not private.blocked_between((select auth.uid()), i.id)
    and (
      exists (select 1 from public.swipes s where s.swiper = (select auth.uid()) and s.target = i.id)
      or (private.is_premium((select auth.uid()))
          and exists (select 1 from public.swipes s
                      where s.swiper = i.id and s.target = (select auth.uid()) and s.action <> 'pass'))
      or exists (select 1 from public.matches m
                 where m.user_a = least((select auth.uid()), i.id) and m.user_b = greatest((select auth.uid()), i.id)));
$$;

-- MARK: Live event

-- As in 20260926000002, without the liker's id in the `like` broadcast: the app reads liked_me again,
-- which decides what it may see. The outbox event (server side only) keeps it for the push.
create or replace function private.on_swipe()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.touch_active(new.swiper);
  if new.action <> 'pass' then
    perform private.broadcast(new.target, 'like', jsonb_build_object('superLike', new.action = 'superlike'));
    perform private.emit('like.received', jsonb_build_object(
      'from', new.swiper, 'to', new.target, 'superLike', new.action = 'superlike'));
  end if;
  return null;
end;
$$;
