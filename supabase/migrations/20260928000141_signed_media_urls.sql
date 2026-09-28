-- Private media: every photo, video, poster and voice intro is served through signed, short-lived URLs.
--
-- The R2 bucket stops being public. The media Worker (cloudflare/media-worker) serves
-- `<media_base_url>/<key>?exp=<unix seconds>&sig=<signature>` only while `exp` is in the future and
-- `sig` = base64url(HMAC-SHA256(media_signing_key, key || '\n' || exp)), without padding. The same
-- signature is computed here, in the Edge Functions (_shared/media_url.ts), in the Worker and in sophros.
--
-- A URL is signed only for what the caller may see:
--   - their own media, always;
--   - someone else's approved profile media (the card only holds approved media), through the card
--     functions below, when that person is onboarded, not paused, not on hold (review, selfie, banned),
--     and neither blocked the other; the viewer must not be on hold either;
--   - chat media (`u/<owner>/chat/...`), through media_urls, only between the two members of an
--     active match, with the same rules.
-- Otherwise the card still carries its keys but no URL. With the private bucket, a key alone opens
-- nothing.
--
-- Compatibility while the bucket goes private: cards keep `key` (and `posterKey`, voiceIntro.key) and
-- gain `url` (and `posterUrl`, voiceIntro.url). The app reads `url` first and falls back to
-- app-config's mediaUrl + key. Without a `media_signing_key` in Vault the URL is unsigned (the public
-- bucket still serves it); without a `media_base_url`, there is no URL at all.
--
-- Vault (scripts/sync-vault.sh, from supabase/functions/.env.<environment>):
--   media_base_url     MEDIA_PUBLIC_URL, e.g. https://media.getdrafft.com
--   media_signing_key  MEDIA_SIGNING_KEY, distinct for staging and production

-- MARK: Signing

-- Expiry: at least an hour ahead, rounded up to the next quarter hour, so the URLs of one card stay the
-- same for 15 minutes (the app and the CDN reuse them).
create function private.media_signer(out base text, out secret bytea, out exp bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select
    (select nullif(rtrim(btrim(decrypted_secret), '/'), '') from vault.decrypted_secrets where name = 'media_base_url'),
    (select nullif(convert_to(btrim(decrypted_secret), 'UTF8'), ''::bytea)
       from vault.decrypted_secrets where name = 'media_signing_key'),
    (ceil((extract(epoch from now()) + 3600) / 900) * 900)::bigint;
$$;

-- One URL, from the values of media_signer (read once per card, not once per key).
create function private.sign_media_key(p_key text, p_base text, p_secret bytea, p_exp bigint)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_key is null or p_base is null then null
    when p_secret is null then p_base || '/' || p_key
    else p_base || '/' || p_key || '?exp=' || p_exp || '&sig='
      || rtrim(translate(encode(
           extensions.hmac(convert_to(p_key || E'\n' || p_exp, 'UTF8'), p_secret, 'sha256'), 'base64'), '+/', '-_'), '=')
  end;
$$;

-- Whether p_viewer may get links to p_owner's media. The single place for these rules: a later state
-- that hides an account (soft delete) belongs here too.
create function private.media_visible(p_owner uuid, p_viewer uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_owner is not null and p_viewer is not null and (
    p_owner = p_viewer
    or (
      exists (
        select 1 from public.profiles p
        where p.id = p_owner and p.onboarded_at is not null and not p.paused and p.moderation is null)
      and exists (select 1 from public.profiles v where v.id = p_viewer and v.moderation is null)
      and not private.blocked_between(p_owner, p_viewer)));
$$;

-- A card with a URL next to each key when p_visible, as stored otherwise.
create function private.sign_card(p_card jsonb, p_visible boolean)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  s record;
  v_media jsonb;
begin
  if p_card is null or not coalesce(p_visible, false) then
    return p_card;
  end if;
  select * into s from private.media_signer();
  select coalesce(jsonb_agg(m || jsonb_build_object(
      'url', private.sign_media_key(m ->> 'key', s.base, s.secret, s.exp),
      'posterUrl', private.sign_media_key(m ->> 'posterKey', s.base, s.secret, s.exp)) order by i), '[]'::jsonb)
  into v_media
  from jsonb_array_elements(coalesce(p_card -> 'media', '[]'::jsonb)) with ordinality as t(m, i);
  p_card := p_card || jsonb_build_object('media', v_media);
  if jsonb_typeof(p_card -> 'voiceIntro') = 'object' then
    p_card := p_card || jsonb_build_object('voiceIntro', (p_card -> 'voiceIntro')
      || jsonb_build_object('url', private.sign_media_key(p_card #>> '{voiceIntro,key}', s.base, s.secret, s.exp)));
  end if;
  return p_card;
end;
$$;

revoke all on function
  private.media_signer(),
  private.sign_media_key(text, text, bytea, bigint),
  private.media_visible(uuid, uuid),
  private.sign_card(jsonb, boolean)
from public;

-- MARK: Links for the app

-- URLs for keys the app already holds: its own media (the profile editor), and chat media (Stream
-- messages carry keys). Returns { key: url } for the keys the caller may open; others are left out.
-- Up to 100 keys per call.
create function public.media_urls(p_keys text[])
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  s record;
  v_urls jsonb;
begin
  if v_me is null then
    perform private.fail('unauthenticated', 'sign in first');
  end if;
  select * into s from private.media_signer();
  select coalesce(jsonb_object_agg(k.key, private.sign_media_key(k.key, s.base, s.secret, s.exp)), '{}'::jsonb)
  into v_urls
  from (
    select distinct key,
      case when key ~ '^u/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/(photos|demo|videos|posters|voice|chat)/[A-Za-z0-9_-]{1,64}\.[a-z0-9]{2,4}$'
        then substr(key, 3, 36)::uuid end as owner
    from unnest(p_keys[1:100]) as u(key)
    where char_length(key) <= 200
  ) k
  where k.owner is not null
    and s.base is not null
    and (
      k.owner = v_me
      or (k.key like 'u/%/chat/%'
          and exists (
            select 1 from public.matches m
            where m.user_a = least(v_me, k.owner) and m.user_b = greatest(v_me, k.owner) and m.ended_at is null)
          and private.media_visible(k.owner, v_me)));
  return v_urls;
end;
$$;

grant execute on function public.media_urls(text[]) to authenticated;

-- MARK: Cards with URLs

-- Discover: unchanged from 20260928000041 but for the signed card.
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
  select private.sign_card(c.card, private.media_visible(r.id, v_me)) || jsonb_build_object(
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

-- Likes: unchanged from 20260926000001 but for the signed card.
create or replace function public.liked_me(p_limit int default 50, p_before timestamptz default null)
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select private.sign_card(c.card, private.media_visible(s.swiper, s.target)) || jsonb_build_object(
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

-- Matches: unchanged from 20260924000003 but for the signed card.
create or replace function public.my_matches()
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
      'matchId', m.id,
      'matchedAt', m.created_at,
      'profile', private.sign_card(c.card, private.media_visible(o.other, (select auth.uid())))
        || jsonb_build_object('age', private.age_of(p.birthdate), 'cardVersion', c.version))
  from public.matches m
  cross join lateral (select case when m.user_a = (select auth.uid()) then m.user_b else m.user_a end as other) o
  join public.profiles p on p.id = o.other
  join public.profile_cards c on c.user_id = o.other
  where (select auth.uid()) in (m.user_a, m.user_b)
    and m.ended_at is null
  order by m.created_at desc;
$$;

-- Cards by id: unchanged from 20260924000003 but for the signed card. `p_known` skips cards whose
-- version the app holds: it refreshes expired URLs by calling again without that version.
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
    and not private.blocked_between((select auth.uid()), i.id)
    and (
      exists (select 1 from public.swipes s where s.swiper = (select auth.uid()) and s.target = i.id)
      or exists (select 1 from public.swipes s where s.swiper = i.id and s.target = (select auth.uid()) and s.action <> 'pass')
      or exists (select 1 from public.matches m
                 where m.user_a = least((select auth.uid()), i.id) and m.user_b = greatest((select auth.uid()), i.id)));
$$;

-- Sessions tab: unchanged from 20260924000004 but for the signed photo.
create or replace function public.upcoming_sessions()
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select to_jsonb(s) || jsonb_build_object(
      'with', jsonb_build_object(
        'id', c.user_id, 'name', c.card ->> 'name',
        'photo', private.sign_card(c.card, private.media_visible(o.other, (select auth.uid()))) -> 'media' -> 0))
  from public.matches m
  join public.sessions s on s.match_id = m.id
  cross join lateral (select case when m.user_a = (select auth.uid()) then m.user_b else m.user_a end as other) o
  join public.profile_cards c on c.user_id = o.other
  where (select auth.uid()) in (m.user_a, m.user_b)
    and m.ended_at is null
    and s.status in ('pending', 'accepted')
    and coalesce(s.chosen_at, s.options[cardinality(s.options)]) > now() - interval '2 hours'
  order by coalesce(s.chosen_at, s.options[1]);
$$;
