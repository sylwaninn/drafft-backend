-- Who liked you (20260928000231): a free account gets a blurred list (opaque handle, super like, date,
-- ThumbHash) and no way to the identity through get_cards or the `like` event; drafft tempo gets the
-- full cards, as soon as it starts.
begin;
create extension if not exists pgtap with schema extensions;
select plan(19);

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

grant execute on all functions in schema pg_temp to authenticated;

create temp table ids as select
  pg_temp.person('Ana') as ana, pg_temp.person('Ben') as ben, pg_temp.person('Cleo') as cleo;
grant select on ids to authenticated;
update public.wallets set super_likes = 1 where user_id = (select cleo from ids);

-- Ben likes Ana, Cleo super likes her. Ana is on the free plan.
set local role authenticated;
select pg_temp.login((select ben from ids));
select public.swipe((select ana from ids), 'like');
select pg_temp.login((select cleo from ids));
select public.swipe((select ana from ids), 'superlike', null, 'see you at the track');
select pg_temp.login((select ana from ids));

-- MARK: Free

create temp table free_likes as select c from public.liked_me() c;
select is((select count(*) from free_likes), 2::bigint, 'a free account sees how many people like it');
select is((select array_agg(distinct k collate "C" order by k collate "C") from free_likes, jsonb_object_keys(c) k),
  array['likeId', 'likedAt', 'superLike', 'thumbhash'], 'and nothing but a handle, the super like, the date and a ThumbHash');
select is((select array_agg(c ->> 'thumbhash' order by c ->> 'thumbhash') from free_likes), array['th-ben', 'th-cleo'],
  'the ThumbHash is the first photo''s');
select is((select c ->> 'superLike' from free_likes where c ->> 'thumbhash' = 'th-cleo'), 'true', 'the super like shows');
select ok((select bool_and(c ->> 'likeId' ~ '^[0-9a-f]{64}$') from free_likes), 'the handle is opaque');
select ok(not exists (select 1 from free_likes, ids
    where c::text like '%' || ids.ben || '%' or c::text like '%' || ids.cleo || '%'),
  'no profile id anywhere in the answer');
select is((select array_agg(c ->> 'likeId' order by c ->> 'likeId') from public.liked_me() c),
  (select array_agg(c ->> 'likeId' order by c ->> 'likeId') from free_likes), 'the handle is stable between calls');
select is((select count(*) from public.get_cards((select array[ben, cleo] from ids))), 0::bigint,
  'get_cards does not give a liker''s card to a free account');

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
  (select array_agg(x order by x) from ids, unnest(array[ben::text, cleo::text]) x),
  'with drafft tempo the likes carry who it is, at once');
select is((select c ->> 'name' from public.liked_me() c where c ->> 'id' = (select cleo::text from ids)), 'Cleo',
  'with the name');
select is((select c ->> 'superLikeNote' from public.liked_me() c where c ->> 'id' = (select cleo::text from ids)),
  'see you at the track', 'and the super like note');
select ok((select bool_and(c ? 'age' and c ? 'cardVersion') from public.liked_me() c), 'the full card, as before');
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
select is((select count(*) from public.liked_me()), 1::bigint, 'and the match leaves the Likes list');

select * from finish();
rollback;
