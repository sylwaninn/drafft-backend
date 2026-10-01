-- Who liked you, free account: a real blurred photo next to the ThumbHash (20260928000231).
--
-- Each blurred like gains `blurUrl`: a signed link of about an hour to a blurred copy of the liker's first
-- photo (the card holds published, approved photos only), or null when there is none, when the liker's
-- media is not visible to the caller (private.media_visible: on hold, blocked...), or without the Vault
-- secrets. The link opens only that blurred copy, made by the media Worker (cloudflare/media-worker,
-- `/b/<mode>/<token>`: 200 px wide, strong blur, WebP without metadata):
--
--   <media_base_url>/b/<mode>/<token>?exp=<unix seconds>&sig=<signature>
--
-- The token hides which photo it is (encrypt-then-MAC, keys derived from media_signing_key; the exact
-- construction is in cloudflare/media-worker/src/blur_token.ts):
--   enc: HMAC-SHA256 of media_signing_key labelled drafft-blur-enc-v1
--   iv: HMAC-SHA256 (under the media_signing_key label drafft-blur-iv-v1) of viewer || '\n' || key || '\n' || exp)[1..16]
--   mac: HMAC-SHA256 of media_signing_key labelled drafft-blur-mac-v1
--   token = base64url(iv || AES-256-CBC-PKCS7(enc, iv, key))
--   sig   = base64url(HMAC-SHA256(mac, mode || '\n' || token || '\n' || exp))
-- No profile id and no media key in clear (keys are u/<user id>/...); the signature binds the mode and
-- the expiry under a key ordinary links do not use, so a blur link never becomes a sharp or sharper one.
-- The iv depends on the viewer and the expiry: two people never get the same token for one photo, and a
-- person's token changes every quarter hour, so nothing links a blurred like to a card seen elsewhere.
-- Everything else in the answer is unchanged.

-- MARK: Blur links

create function private.blur_url(p_key text, p_viewer uuid, p_base text, p_secret bytea, p_exp bigint)
returns text
language sql
immutable
set search_path = ''
as $$
  with k as (
    select
      extensions.hmac(convert_to('drafft-blur-enc-v1', 'UTF8'), p_secret, 'sha256') as enc,
      extensions.hmac(convert_to('drafft-blur-mac-v1', 'UTF8'), p_secret, 'sha256') as mac,
      substring(extensions.hmac(
        convert_to(p_viewer::text || E'\n' || p_key || E'\n' || p_exp, 'UTF8'),
        extensions.hmac(convert_to('drafft-blur-iv-v1', 'UTF8'), p_secret, 'sha256'), 'sha256') from 1 for 16) as iv
  ),
  t as (
    select k.mac, rtrim(translate(encode(
        k.iv || extensions.encrypt_iv(convert_to(p_key, 'UTF8'), k.enc, k.iv, 'aes-cbc/pad:pkcs'), 'base64'),
        E'+/\n', '-_'), '=') as token
    from k
  )
  -- 'l1': the Likes rendition (BLUR_MODES in the Worker).
  select case when p_key is null or p_viewer is null or p_base is null or p_secret is null then null
    else p_base || '/b/l1/' || t.token || '?exp=' || p_exp || '&sig='
      || rtrim(translate(encode(
           extensions.hmac(convert_to('l1' || E'\n' || t.token || E'\n' || p_exp, 'UTF8'), t.mac, 'sha256'), 'base64'),
           '+/', '-_'), '=')
    end
  from t;
$$;

revoke all on function private.blur_url(text, uuid, text, bytea, bigint) from public, anon, authenticated;

-- MARK: Likes

-- As in 20260928000231, plus `blurUrl` in the blurred shape. The signer is read once per call.
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
      'thumbhash', ph.photo ->> 'thumbhash',
      'blurUrl', case when private.media_visible(s.swiper, s.target)
        then private.blur_url(ph.photo ->> 'key', s.target, v.base, v.secret, v.exp) end)
    end
  from (select (select auth.uid()) as me, private.is_premium((select auth.uid())) as premium, g.base, g.secret, g.exp
        from private.media_signer() g) v
  join public.swipes s on s.target = v.me
  join public.profiles p on p.id = s.swiper
  join public.profile_cards c on c.user_id = s.swiper
  left join lateral (select m as photo
                     from jsonb_array_elements(coalesce(c.card -> 'media', '[]'::jsonb)) with ordinality as t(m, i)
                     where m ->> 'kind' = 'photo'
                     order by i
                     limit 1) ph on true
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
