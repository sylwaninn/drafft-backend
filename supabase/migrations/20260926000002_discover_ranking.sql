-- Discover: activity that really counts, boosts that stay nearby, and a ranking beyond "nearest first".
--
-- - `last_active_at` only moved with set_location, which the app calls once at sign-up: 30 days later
--   everyone left every deck, however active. Browsing Discover, swiping and boosting now count too.
-- - Boosts promise "the top of decks nearby", but with no distance limit a boost anywhere in the world
--   went to the top. Boosted people now come first only within 50 km (or the viewer's own limit).
-- - A boost could be spent without a location or a photo, where nobody sees it: refused now.
-- - Paused people can't browse or boost (paused profiles are frozen, 20260926000001).
-- - Without a location, the viewer got an empty or random deck: `location_required` instead, so the
--   app can ask for it.
-- - Everyone who isn't super liking you or boosted used to be ranked by distance alone, so someone
--   500 m away and gone for weeks beat someone 3 km away and active today. They're now scored on
--   distance and activity, with bonuses for sports in common and for having liked you already.

-- Throttled: at most one write per person every 5 minutes, however much they browse.
create function private.touch_active(p_user uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.profiles set last_active_at = now()
    where id = p_user and last_active_at < now() - interval '5 minutes';
$$;

-- A swipe counts as activity (same events as before).
create or replace function private.on_swipe()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.touch_active(new.swiper);
  if new.action <> 'pass' then
    perform private.broadcast(new.target, 'like', jsonb_build_object('from', new.swiper, 'superLike', new.action = 'superlike'));
    perform private.emit('like.received', jsonb_build_object(
      'from', new.swiper, 'to', new.target, 'superLike', new.action = 'superlike'));
  end if;
  return null;
end;
$$;

-- Only when someone could see the boost: not paused (20260926000001), onboarded, with a photo and a
-- location.
create or replace function public.start_boost()
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  v_ends timestamptz;
begin
  perform private.require_unpaused(v_me);
  if not exists (
    select 1 from public.profiles p join private.locations l on l.user_id = p.id
    where p.id = v_me and p.onboarded_at is not null and p.photo_count > 0) then
    perform private.fail('not_visible', 'your profile is hidden, nobody would see the boost');
  end if;
  update public.wallets
    set boosts = boosts - 1, boost_ends_at = now() + interval '30 minutes'
    where user_id = v_me and boosts > 0 and coalesce(boost_ends_at, '-infinity') <= now()
    returning boost_ends_at into v_ends;
  if v_ends is null then
    perform private.fail('no_boost', 'no boost left, or one is already running');
  end if;
  perform private.touch_active(v_me);
  return v_ends;
end;
$$;

-- Discover's candidates: the nearest people who pass the filters, nearest first, `p_count` at most.
-- A walk of the location index (KNN) that stops once it has enough of them, so the cost doesn't grow
-- with how many people live nearby. PostGIS underestimates how many people a radius holds, so the
-- planner would rather sort the whole radius (0.5 s at 50,000 profiles instead of 3 ms): sorting is
-- turned off here, for these two queries only, which leaves the index walk.
create function private.nearby_candidates(
  p_viewer uuid,
  p_viewer_gender public.gender,
  p_viewer_sports text[],
  p_filters jsonb,
  p_geo extensions.geography,
  p_max_m float8,
  p_count int
)
returns uuid[]
language plpgsql
stable
security definer
set search_path = ''
set enable_sort = off
as $$
begin
  if p_max_m is null then
    return (
      select coalesce(array_agg(n.user_id), '{}') from (
        select l.user_id
        from private.locations l
        join public.profiles p on p.id = l.user_id
        where private.eligible(p, p_viewer, p_viewer_gender, p_viewer_sports, p_filters)
        order by l.geo operator(extensions.<->) p_geo
        limit p_count) n);
  end if;
  return (
    select coalesce(array_agg(n.user_id), '{}') from (
      select l.user_id
      from private.locations l
      join public.profiles p on p.id = l.user_id
      where extensions.st_dwithin(l.geo, p_geo, p_max_m)
        and private.eligible(p, p_viewer, p_viewer_gender, p_viewer_sports, p_filters)
      order by l.geo operator(extensions.<->) p_geo
      limit p_count) n);
end;
$$;

-- One batch of cards for the deck, best first:
-- 1. people who super liked you (with their note);
-- 2. people boosted right now, within 50 km (or maxDistanceKm if set);
-- 3. everyone else, by score: distance times activity, with a bonus for sports in common and for
--    people who already liked you (a right swipe on them is a match).
-- Filters (all optional): maxDistanceKm (null = any), minAge, maxAge (null = no upper limit),
-- audience (genders), sports, sharedSportsOnly. Audience defaults to the viewer's own preferences, and
-- preferences are mutual: you only see people who want to see you. Details: docs/matching.md.
create or replace function public.discover(p_filters jsonb default '{}', p_limit int default 20)
returns setof jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  v_limit int := least(greatest(p_limit, 1), 50);
  v_gender public.gender;
  v_sports text[];
  v_geo extensions.geography;
  v_max_m float8 := (p_filters ->> 'maxDistanceKm')::float8 * 1000;
  v_filters jsonb;
  v_near uuid[];
begin
  if v_me is null then
    perform private.fail('unauthenticated', 'sign in first');
  end if;
  perform private.require_unpaused(v_me);
  select p.gender, p.sport_ids, l.geo,
    -- No audience in the filters: the viewer's own preferences.
    case when jsonb_array_length(coalesce(p_filters -> 'audience', '[]')) = 0
      then coalesce(p_filters, '{}') || jsonb_build_object('audience', to_jsonb(p.interested_in))
      else p_filters end
  into v_gender, v_sports, v_geo, v_filters
  from public.profiles p
  left join private.locations l on l.user_id = p.id
  where p.id = v_me;
  if v_geo is null then
    perform private.fail('location_required', 'share your location to see people nearby');
  end if;
  perform private.touch_active(v_me);

  -- Twice the batch, so the score has room to reorder (each extra card walks further: see
  -- docs/matching.md, Performance).
  v_near := private.nearby_candidates(v_me, v_gender, v_sports, v_filters, v_geo, v_max_m, v_limit * 2);

  return query
  with pool as (
    -- Pinned first: they super liked you.
    select s.swiper as id, true as super_liked_me, false as boosted, s.note
    from public.swipes s
    where s.target = v_me and s.action = 'superlike'
    union all
    -- Pinned next: boosted right now, nearby.
    select w.user_id, false, true, null
    from public.wallets w
    join private.locations l on l.user_id = w.user_id
    where w.boost_ends_at > now() and extensions.st_dwithin(l.geo, v_geo, coalesce(v_max_m, 50000))
    union all
    -- Everyone else, reordered by score below.
    select n.id, false, false, null
    from unnest(v_near) as n(id)
  ),
  ranked as (
    select distinct on (p.id)
      p.id, p.birthdate, pool.super_liked_me, pool.boosted, pool.note,
      extensions.st_distance(l.geo, v_geo) as meters,
      -- Score = proximity x activity x bonuses, so being far away or long gone each sink a card.
      -- Proximity: 1 next door, 0.5 at 5 km, 0.17 at 25 km.
      (1 / (1 + extensions.st_distance(l.geo, v_geo) / 5000))
      -- Activity: 1 right now, 0.5 three days ago, 0.13 three weeks ago.
      * (1 / (1 + extract(epoch from now() - p.last_active_at)::float8 / 259200))
      -- Sports in common: +25% each, up to +50%.
      * (1 + 0.25 * least(cardinality(array(select unnest(p.sport_ids) intersect select unnest(v_sports))), 2))
      -- They already liked you (a right swipe is a match): +50%.
      * case when exists (
          select 1 from public.swipes s where s.swiper = p.id and s.target = v_me and s.action = 'like')
        then 1.5 else 1 end as score
    from pool
    join public.profiles p on p.id = pool.id
    join private.locations l on l.user_id = p.id
    where (v_max_m is null or extensions.st_dwithin(l.geo, v_geo, v_max_m))
      and private.eligible(p, v_me, v_gender, v_sports, v_filters)
    order by p.id, pool.super_liked_me desc, pool.boosted desc
  )
  select c.card || jsonb_build_object(
      'age', private.age_of(r.birthdate),
      'distanceKm', greatest(1, round(r.meters / 1000))::int,
      'superLikedMe', r.super_liked_me,
      'superLikeNote', r.note,
      'cardVersion', c.version)
  from ranked r
  join public.profile_cards c on c.user_id = r.id
  order by r.super_liked_me desc, r.boosted desc, r.score desc, r.meters, r.id
  limit v_limit;
end;
$$;
