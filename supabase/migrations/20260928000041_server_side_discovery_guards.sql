-- The app's rules, enforced by the database too, not only by the app's screens.
--
-- - Discover, swipe, undo and boost need a finished onboarding (`onboarding_required`). Onboarding is
--   where the 18+ check happens (complete_onboarding), and the birthdate is locked after it.
-- - A like or super like also checks the person liked: 18 or older, and their preferences include the
--   liker's gender (`not_eligible`), as Discover does. Not needed when they already liked the liker
--   (answering from the Likes tab). A pass never is: it only hides a card.
-- - Reports need an onboarded account with no hold (`onboarding_required`, `moderated`), and at most
--   10 in 24 hours (`report_limit`). A report never holds anyone by itself: it reaches the team, who
--   decide in sophros (the automatic hold for underage or 3 reporters in 30 days is removed). A paused
--   person can still report (docs/matching.md, Pause).
-- - An account on hold can't add profile media or register a push token (`moderated`). A paused one
--   still can: editing the profile stays open while paused. Data export and deletion stay open to all.

-- MARK: Guards

create function private.require_onboarded(p_user uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.profiles where id = p_user and onboarded_at is not null) then
    perform private.fail('onboarding_required', 'finish your profile first');
  end if;
end;
$$;

-- A hold set by the team (review, selfie, banned), with the same answer as require_unpaused. Unlike it,
-- the owner's own pause is not refused.
create function private.require_not_held(p_user uuid)
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

revoke all on function private.require_onboarded(uuid), private.require_not_held(uuid) from public;

-- MARK: Discover

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
  perform private.require_onboarded(v_me);
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


-- MARK: Swipes

create or replace function public.swipe(
  p_target uuid,
  p_action public.swipe_action,
  p_opener jsonb default null,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  v_match uuid;
begin
  if v_me is null then
    perform private.fail('unauthenticated', 'sign in first');
  end if;
  perform private.require_onboarded(v_me);
  if p_target = v_me then
    perform private.fail('invalid_target', 'cannot swipe yourself');
  end if;

  -- Serialize the pair: two people liking each other at the same instant must still match.
  perform pg_advisory_xact_lock(hashtextextended(least(v_me, p_target)::text || greatest(v_me, p_target)::text, 0));

  if not exists (select 1 from public.profiles where id = p_target and onboarded_at is not null)
     or private.blocked_between(v_me, p_target) then
    perform private.fail('not_found', 'profile not available');
  end if;

  -- A like reaches only someone Discover could have shown: an adult who wants to see the liker's
  -- gender. Answering their own like is always possible.
  if p_action <> 'pass'
     and not exists (select 1 from public.swipes where swiper = p_target and target = v_me and action <> 'pass')
     and not exists (
       select 1 from public.profiles t, public.profiles me
       where t.id = p_target and me.id = v_me
         and t.birthdate <= current_date - interval '18 years'
         and (cardinality(t.interested_in) = 0 or me.gender = any (t.interested_in))) then
    perform private.fail('not_eligible', 'this person is not looking for you');
  end if;

  if p_action = 'like' and not private.is_premium(v_me)
     and (select count(*) from public.swipes
          where swiper = v_me and action = 'like' and created_at > now() - interval '24 hours') >= 20 then
    perform private.fail('daily_like_limit', 'no likes left today');
  end if;

  if p_action = 'superlike' then
    update public.wallets set super_likes = super_likes - 1 where user_id = v_me and super_likes > 0;
    if not found then
      perform private.fail('no_super_likes', 'no super likes left');
    end if;
  end if;

  insert into public.swipes (swiper, target, action, opener, note)
  values (v_me, p_target, p_action,
          case when p_action <> 'pass' then p_opener end,
          case when p_action = 'superlike' then nullif(trim(p_note), '') end)
  on conflict (swiper, target) do nothing;
  if not found then
    perform private.fail('already_swiped', 'already swiped');
  end if;

  if p_action <> 'pass' and exists (
    select 1 from public.swipes where swiper = p_target and target = v_me and action <> 'pass') then
    insert into public.matches (user_a, user_b)
    values (least(v_me, p_target), greatest(v_me, p_target))
    on conflict (user_a, user_b) do nothing
    returning id into v_match;
  end if;

  return jsonb_build_object('matched', v_match is not null, 'matchId', v_match);
end;
$$;

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
  perform private.require_onboarded(v_me);
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

-- MARK: Boost

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
  perform private.require_onboarded(v_me);
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

-- MARK: Reports

-- The per-reporter limit reads the last 24 hours of someone's reports.
create index reports_reporter_idx on public.reports (reporter, created_at);

create or replace function public.report_user(p_target uuid, p_reason public.report_reason, p_details text default '')
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
begin
  if v_me is null then
    perform private.fail('unauthenticated', 'sign in first');
  end if;
  perform private.require_onboarded(v_me);
  perform private.require_not_held(v_me);
  -- One reporter at a time, so two reports sent together can't both pass the limit.
  perform pg_advisory_xact_lock(hashtextextended('report:' || v_me::text, 0));
  if (select count(*) from public.reports
      where reporter = v_me and created_at > now() - interval '24 hours') >= 10 then
    perform private.fail('report_limit', 'too many reports today, contact us instead');
  end if;
  insert into public.reports (reporter, reported, reason, details)
  values (v_me, p_target, p_reason, coalesce(p_details, ''));
  perform public.block_user(p_target);
end;
$$;

-- Every report reaches the team, and only the team puts an account on hold (sophros). No report holds
-- anyone by itself, whatever its reason or count.
create or replace function private.on_report()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.emit('report.created', jsonb_build_object('id', new.id));
  return null;
end;
$$;

-- MARK: Held accounts

create or replace function public.add_profile_media(
  p_key text,
  p_width int,
  p_height int,
  p_thumbhash text default null,
  p_kind public.media_kind default 'photo',
  p_duration real default null,
  p_poster_key text default null
)
returns public.profile_media
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  v_position smallint;
  v_row public.profile_media;
begin
  perform private.require_not_held(v_me);
  perform 1 from public.profiles where id = v_me for update;
  select coalesce(max(position) + 1, 0) into v_position from public.profile_media where user_id = v_me;
  if v_position > 8 then
    perform private.fail('media_limit', 'up to 9 photos and videos');
  end if;
  insert into public.profile_media (user_id, kind, key, position, width, height, thumbhash, duration, poster_key)
  values (v_me, p_kind, p_key, v_position, p_width, p_height, p_thumbhash, p_duration, p_poster_key)
  returning * into v_row;
  return v_row;
end;
$$;

create or replace function public.register_push_token(p_token text, p_environment text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_not_held((select auth.uid()));
  insert into public.push_tokens (token, user_id, environment)
  values (p_token, (select auth.uid()), p_environment)
  on conflict (token) do update
    set user_id = excluded.user_id, environment = excluded.environment, updated_at = now();
end;
$$;
