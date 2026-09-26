-- Latency of the hot read paths on synthetic data. Everything runs in a rolled-back transaction.
--   docker exec -i supabase_db_drafft-backend psql -U postgres -v n=50000 < scripts/bench.sql
-- Measures database time only; add the network round trip (10-80 ms) for what the app sees.

\set ON_ERROR_STOP on
\if :{?n}
\else
  \set n 50000
\endif

begin;
set local client_min_messages = warning;

\echo Generating :n profiles around Paris...
\timing on
insert into auth.users (id, email, aud, role, instance_id)
select gen_random_uuid(), 'bench' || i || '@bench.dev', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'
from generate_series(1, :n) i;

update public.profiles p set
  name = 'P' || substr(p.id::text, 1, 6),
  gender = (array['woman', 'man', 'nonbinary']::public.gender[])[1 + (abs(hashtext(p.id::text)) % 20 = 0)::int * 2 + (abs(hashtext(p.id::text)) % 2)],
  interested_in = case abs(hashtext(p.id::text || 'i')) % 3 when 0 then '{man}' when 1 then '{woman}' else '{}' end::public.gender[],
  birthdate = current_date - make_interval(years => 20 + abs(hashtext(p.id::text || 'a')) % 30),
  bio = repeat('Training for a marathon, coffee after. ', 5),
  icebreaker = '{"kind": "hotTake", "text": "Pools are better than the sea."}'
where p.id in (select id from auth.users where email like '%@bench.dev');

-- Fresh statistics, or the trigger functions cache sequential-scan plans for this bulk load.
analyze public.profiles, public.profile_cards, public.wallets;

insert into public.profile_sports (user_id, sport_id, per_week, position)
select u.id, s.id, 1 + abs(hashtext(u.id::text || s.id)) % 5, (row_number() over (partition by u.id order by s.id) - 1)::smallint
from auth.users u
cross join lateral (
  select id from public.sports order by hashtext(u.id::text || id) limit 3) s
where u.email like '%@bench.dev';

insert into public.profile_media (user_id, key, position, width, height, thumbhash, status)
select u.id, 'u/' || u.id || '/photos/' || k || '.jpg', (k - 1)::smallint, 1200, 1600, 'YJqGPQw7sFlslqhFafSE+Q6oJ1h2iHB2Rw', 'approved'
from auth.users u cross join generate_series(1, 5) k
where u.email like '%@bench.dev';

-- Île-de-France box, snapped like set_location().
insert into private.locations (user_id, geo)
select u.id, extensions.st_setsrid(extensions.st_makepoint(
    round((2.10 + (abs(hashtext(u.id::text || 'x')) % 10000) / 10000.0 * 0.50)::numeric, 2)::float8,
    round((48.70 + (abs(hashtext(u.id::text || 'y')) % 10000) / 10000.0 * 0.35)::numeric, 2)::float8), 4326)::extensions.geography
from auth.users u where u.email like '%@bench.dev';

update public.profiles set onboarded_at = now()
where id in (select id from auth.users where email like '%@bench.dev');

-- The benchmark viewer: already swiped 2,000 people, like a heavy user after a few months.
create temp table viewer as
  select p.id from public.profiles p where p.gender = 'woman' and p.interested_in = '{man}' limit 1;
insert into public.swipes (swiper, target, action)
select (select id from viewer), p.id, 'pass'
from public.profiles p where p.gender = 'man' and p.id <> (select id from viewer) limit 2000;
analyze;
\timing off

select set_config('request.jwt.claims', json_build_object('sub', (select id from viewer), 'role', 'authenticated')::text, true);

\echo
\echo == discover, 10 km, default filters (x5, warm cache)
\timing on
select count(*) from public.discover('{"maxDistanceKm": 10}');
select count(*) from public.discover('{"maxDistanceKm": 10}');
select count(*) from public.discover('{"maxDistanceKm": 10}');
select count(*) from public.discover('{"maxDistanceKm": 10}');
select count(*) from public.discover('{"maxDistanceKm": 10}');
\echo == discover, any distance, 2 sports + age 25-35
select count(*) from public.discover('{"minAge": 25, "maxAge": 35, "sports": ["running", "padel"]}');
select count(*) from public.discover('{"minAge": 25, "maxAge": 35, "sports": ["running", "padel"]}');
\echo == one card by id (get_cards)
select count(*) from public.get_cards(array(select target from public.swipes where swiper = (select id from viewer) limit 1));
select count(*) from public.get_cards(array(select target from public.swipes where swiper = (select id from viewer) limit 1));
\echo == 20 cards by id (refresh after launch)
select count(*) from public.get_cards(array(select target from public.swipes where swiper = (select id from viewer) limit 20));
\echo == edit profile: bio update + card rebuild
update public.profiles set bio = 'Changed' where id = (select id from viewer);
\timing off

\echo
\echo == payload size of one discover batch (20 cards)
select pg_size_pretty(sum(octet_length(c::text))) as batch, pg_size_pretty(avg(octet_length(c::text))::bigint) as per_card
from public.discover('{"maxDistanceKm": 10}') c;

\echo
\echo == Building one complete profile, step by step, as onboarding does
\timing off
insert into auth.users (id, email, aud, role, instance_id)
values ('11111111-1111-4111-8111-111111111111', 'builder@bench.dev', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
select set_config('request.jwt.claims', '{"sub": "11111111-1111-4111-8111-111111111111", "role": "authenticated"}', true);
\timing on
\echo -- identity, vitals, icebreaker, voice intro (one PATCH)
update public.profiles set
  name = 'Chloé', birthdate = '1994-05-12', gender = 'woman', interested_in = '{man}', pronouns = 'she/her',
  neighborhood = 'Canal Saint-Martin', bio = repeat('Marathoner, negative splits, croissants at km 33. ', 6),
  goal = 'Sub 3:15 in Berlin', favorite_spot = 'Parc des Buttes-Chaumont',
  drinks = 'Socially', smokes = 'Never', diet = 'Omnivore', chronotype = 'Early bird',
  icebreaker = '{"kind": "twoTruths", "statements": ["I ran Paris in 3:21", "I hate croissants", "I swim at 6am"], "lieIndex": 1}',
  voice_intro_key = 'u/11111111-1111-4111-8111-111111111111/voice/intro.m4a',
  voice_duration = 14.2,
  voice_levels = array(select random()::real from generate_series(1, 60))
where id = '11111111-1111-4111-8111-111111111111';
\echo -- sports
select public.set_sports('[{"sport": "running", "perWeek": 4}, {"sport": "trail", "perWeek": 1}, {"sport": "yoga", "perWeek": 2}]');
\echo -- prompts
select public.set_prompts('[{"question": "My ideal Sunday session", "answer": "32k long run, negative split, croissant at km 33."}, {"question": "A stat I am weirdly proud of", "answer": "Four years without skipping a Tuesday interval."}, {"question": "I will know it is a match if", "answer": "You can hold a conversation at marathon pace."}]');
\echo -- 5 photos + 1 video, registered one by one
select count(*) from (
  select public.add_profile_media('u/11111111-1111-4111-8111-111111111111/photos/' || k || '.jpg', 1536, 2048, 'YJqGPQw7sFlslqhFafSE+Q6oJ1h2iHB2Rw')
  from generate_series(1, 5) k) t;
select (public.add_profile_media('u/11111111-1111-4111-8111-111111111111/videos/1.mp4', 720, 1280, 'YJqGPQw7sFlslqhFafSE+Q6oJ1h2iHB2Rw',
  'video', 12.5, 'u/11111111-1111-4111-8111-111111111111/posters/1.jpg')).id is not null;
select public.set_location(48.8710, 2.3650);
\echo -- moderation approves all 6 (service side)
update public.profile_media set status = 'approved' where user_id = '11111111-1111-4111-8111-111111111111';
\echo -- complete_onboarding
select public.complete_onboarding();
\echo -- full card rebuild from scratch (what every edit costs)
select private.rebuild_card('11111111-1111-4111-8111-111111111111');
select private.rebuild_card('11111111-1111-4111-8111-111111111111');
select private.rebuild_card('11111111-1111-4111-8111-111111111111');
\echo -- read the finished profile as another person would (get_cards)
\timing off
select set_config('request.jwt.claims', json_build_object('sub', (select id from viewer), 'role', 'authenticated')::text, true);
insert into public.swipes (swiper, target, action) select id, '11111111-1111-4111-8111-111111111111', 'pass' from viewer;
\timing on
select count(*) from public.get_cards(array['11111111-1111-4111-8111-111111111111'::uuid]);
select count(*) from public.get_cards(array['11111111-1111-4111-8111-111111111111'::uuid]);
\timing off
select 'card: ' || pg_size_pretty(octet_length(card::text)::bigint) || ', ' || jsonb_array_length(card -> 'media') || ' media, version ' || version as built
from public.profile_cards where user_id = '11111111-1111-4111-8111-111111111111';

rollback;
