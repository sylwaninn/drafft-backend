-- Who liked you (20260928000231, 20261001000301): a free account gets a blurred list (opaque handle,
-- super like, date, ThumbHash, a link to a blurred copy of the first photo) and no way to the identity
-- through get_cards, the `like` event or the blur link; drafft tempo gets the full cards, as soon as it
-- starts.
begin;
create extension if not exists pgtap with schema extensions;
select plan(27);

-- The same Vault secrets as an environment, for this transaction only.
delete from vault.secrets where name in ('media_base_url', 'media_signing_key');
select vault.create_secret('https://media.test/', 'media_base_url');
select vault.create_secret('test-signing-key', 'media_signing_key');

-- MARK: Blur link

-- Same vector as cloudflare/media-worker/src/blur_token_test.ts.
select is(
  private.blur_url('u/0b6f1f5e-8f0c-4a5e-9d3b-2f8a1c7e4d10/photos/a.jpg', '11111111-1111-4111-8111-111111111111',
    'https://media.test', convert_to('test-signing-key', 'UTF8'), 1700000000),
  'https://media.test/b/l1/rW0cnTaXrrj8Z4hQp97dJI-BgoGXMKE7ud653e6zZ9kmW6DUjgd8tDoDLA9qfMmGWGKf_wdJK8R83jleIk9RABcahaYnQ2NooyZ4YHeOVVw'
    || '?exp=1700000000&sig=KUDgBV_JAKiscRBVgqlwEbDSBKmt3jBcQ2eFuMe4otI',
  'the blur link is the media Worker''s encrypt-then-MAC token');
select is(private.blur_url('u/x/photos/a.jpg', gen_random_uuid(), 'https://media.test', null, 1), null,
  'no signing key: no blur link (never an unsigned one)');
select ok(not has_function_privilege('authenticated', 'private.blur_url(text, uuid, text, bytea, bigint)', 'execute'),
  'nobody outside computes blur links');

create function pg_temp.person(p_name text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id)
  values (v_id, lower(p_name) || '@test.dev', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  update public.profiles
    set name = p_name, gender = 'woman', birthdate = current_date - make_interval(years => 30, days => 10)
    where id = v_id;
  insert into public.profile_sports (user_id, sport_id, per_week, position) values (v_id, 'running', 2, 0);
  insert into public.profile_media (user_id, key, position, width, height, thumbhash, status)
    values (v_id, 'u/' || v_id || '/photos/1.jpg', 0, 1200, 1600, 'th-' || lower(p_name), 'approved');
  insert into private.locations (user_id, geo)
    values (v_id, extensions.st_setsrid(extensions.st_makepoint(2.35, 48.86), 4326)::extensions.geography);
  update public.profiles set onboarded_at = now() where id = v_id;
  return v_id;
end $$;

create function pg_temp.login(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

-- The blur link Ana should get for a media key, with this quarter hour's expiry.
create function pg_temp.blur_link(p_key text, p_viewer uuid) returns text language sql security definer as $$
  select private.blur_url(p_key, p_viewer, g.base, g.secret, g.exp) from private.media_signer() g;
$$;

grant execute on all functions in schema pg_temp to authenticated;

create temp table ids as select
  pg_temp.person('Ana') as ana, pg_temp.person('Ben') as ben, pg_temp.person('Cleo') as cleo,
  pg_temp.person('Dan') as dan;
grant select on ids to authenticated;
update public.wallets set super_likes = 1 where user_id = (select cleo from ids);
-- Dan has no photo left.
delete from public.profile_media where user_id = (select dan from ids);

-- Ben likes Ana, Cleo super likes her. Ana is on the free plan.
set local role authenticated;
select pg_temp.login((select ben from ids));
select public.swipe((select ana from ids), 'like');
select pg_temp.login((select cleo from ids));
select public.swipe((select ana from ids), 'superlike', null, 'see you at the track');
select pg_temp.login((select dan from ids));
select public.swipe((select ana from ids), 'like');
select pg_temp.login((select ana from ids));

-- MARK: Free

create temp table free_likes as select c from public.liked_me() c;
select is((select count(*) from free_likes), 3::bigint, 'a free account sees how many people like it');
select is((select array_agg(distinct k collate "C" order by k collate "C") from free_likes, jsonb_object_keys(c) k),
  array['blurUrl', 'likeId', 'likedAt', 'superLike', 'thumbhash'],
  'and nothing but a handle, the super like, the date, a ThumbHash and a blur link');
select is((select array_agg(c ->> 'thumbhash' order by c ->> 'thumbhash') from free_likes where c ->> 'thumbhash' is not null),
  array['th-ben', 'th-cleo'], 'the ThumbHash is the first photo''s');
select ok((select bool_and(c ->> 'blurUrl' ~ '^https://media\.test/b/l1/[A-Za-z0-9_-]{100,}\?exp=[0-9]+&sig=[A-Za-z0-9_-]{43}$')
  from free_likes where c ->> 'thumbhash' is not null), 'a liker with a photo comes with a signed blur link');
select is((select array_agg(c ->> 'blurUrl' order by c ->> 'thumbhash') from free_likes
    where c ->> 'thumbhash' is not null),
  (select array[pg_temp.blur_link('u/' || ben || '/photos/1.jpg', ana), pg_temp.blur_link('u/' || cleo || '/photos/1.jpg', ana)]
   from ids),
  'which stands for that first photo, for this viewer');
select ok(not exists (select 1 from free_likes where c::text like '%/photos/%' or c::text like '%sig=%' and c::text like '%/u/%'),
  'no media key and no sharp link anywhere in the answer');
select ok((select (c -> 'blurUrl') = 'null'::jsonb and (c -> 'thumbhash') = 'null'::jsonb from free_likes
    where c ->> 'thumbhash' is null), 'a liker without a photo: no blur link');
select is((select c ->> 'superLike' from free_likes where c ->> 'thumbhash' = 'th-cleo'), 'true', 'the super like shows');
select ok((select bool_and(c ->> 'likeId' ~ '^[0-9a-f]{64}$') from free_likes), 'the handle is opaque');
select ok(not exists (select 1 from free_likes, ids
    where c::text like '%' || ids.ben || '%' or c::text like '%' || ids.cleo || '%' or c::text like '%' || ids.dan || '%'),
  'no profile id anywhere in the answer');
select is((select array_agg(c ->> 'likeId' order by c ->> 'likeId') from public.liked_me() c),
  (select array_agg(c ->> 'likeId' order by c ->> 'likeId') from free_likes), 'the handle is stable between calls');
select is((select count(*) from public.get_cards((select array[ben, cleo] from ids))), 0::bigint,
  'get_cards does not give a liker''s card to a free account');

-- A viewer on hold gets no links (private.media_visible); a liker on hold is paused, so not listed.
reset role;
update public.profiles set moderation = 'review' where id = (select ana from ids);
set local role authenticated;
select pg_temp.login((select ana from ids));
select is((select array[count(*), count(c ->> 'blurUrl')] from public.liked_me() c), array[3, 0]::bigint[],
  'a viewer on hold gets no blur link');
reset role;
update public.profiles set moderation = null where id = (select ana from ids);
set local role authenticated;
select pg_temp.login((select ana from ids));

-- The live event carries no id, and the handle cannot be computed from outside.
reset role;
select ok(not has_function_privilege('authenticated', 'private.like_handle(uuid, uuid)', 'execute'),
  'the handle cannot be computed from outside');
select ok(not has_table_privilege('authenticated', 'private.like_handle_key', 'select'), 'nor its key read');
select ok(exists (select 1 from realtime.messages
    where topic = 'user:' || (select ana from ids) and event = 'like'
      and payload ->> 'from' is null and (payload -> 'payload' ->> 'from') is null),
  'the like event names nobody');

-- MARK: drafft tempo

update public.wallets set premium_until = now() + interval '1 month' where user_id = (select ana from ids);
set local role authenticated;
select pg_temp.login((select ana from ids));
select is((select array_agg(c ->> 'id' order by c ->> 'id') from public.liked_me() c),
  (select array_agg(x order by x) from ids, unnest(array[ben::text, cleo::text, dan::text]) x),
  'with drafft tempo the likes carry who it is, at once');
select is((select c ->> 'name' from public.liked_me() c where c ->> 'id' = (select cleo::text from ids)), 'Cleo',
  'with the name');
select is((select c ->> 'superLikeNote' from public.liked_me() c where c ->> 'id' = (select cleo::text from ids)),
  'see you at the track', 'and the super like note');
select ok((select bool_and(c ? 'age' and c ? 'cardVersion' and not c ? 'blurUrl') from public.liked_me() c),
  'the full card, as before');
select is((select count(*) from public.get_cards((select array[ben, cleo] from ids))), 2::bigint,
  'get_cards gives the likers'' cards to drafft tempo');

-- Expired: blurred again.
reset role;
update public.wallets set premium_until = now() - interval '1 second' where user_id = (select ana from ids);
set local role authenticated;
select pg_temp.login((select ana from ids));
select ok((select bool_and(not c ? 'id') from public.liked_me() c), 'when drafft tempo ends, the list is blurred again');

-- A card you swiped or matched stays readable on the free plan.
select public.swipe((select ben from ids), 'like');
select is((select count(*) from public.get_cards((select array[ben] from ids))), 1::bigint,
  'a match''s card is readable without drafft tempo');
select is((select count(*) from public.liked_me()), 2::bigint, 'and the match leaves the Likes list');

select * from finish();
rollback;
