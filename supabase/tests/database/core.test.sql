-- Core behaviour: signup, cards, discover filters, swipes and matches, RLS, blocking, sessions, events.
-- Run with `supabase test db`.

begin;
create extension if not exists pgtap with schema extensions;
select plan(40);

-- MARK: Helpers (run as postgres)

-- A fully onboarded, discoverable person.
create function pg_temp.person(
  p_name text, p_gender public.gender, p_interested public.gender[], p_age int,
  p_lat float8, p_lng float8, p_sports text[] default array['running']
) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id)
  values (v_id, lower(p_name) || '@test.dev', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  update public.profiles
    set name = p_name, gender = p_gender, interested_in = p_interested,
        birthdate = current_date - make_interval(years => p_age, days => 10)
    where id = v_id;
  insert into public.profile_sports (user_id, sport_id, per_week, position)
    select v_id, s, 2, (o - 1)::smallint from unnest(p_sports) with ordinality as t(s, o);
  insert into public.profile_media (user_id, key, position, width, height, status)
    values (v_id, 'u/' || v_id || '/photos/1.jpg', 0, 1200, 1600, 'approved');
  insert into private.locations (user_id, geo)
    values (v_id, extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography);
  update public.profiles set onboarded_at = now() where id = v_id;
  return v_id;
end $$;

create function pg_temp.login(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

create function pg_temp.deck_ids(p_filters jsonb default '{}') returns uuid[] language sql as $$
  select coalesce(array_agg((c ->> 'id')::uuid), '{}') from public.discover(p_filters) c;
$$;

-- Paris, Canal Saint-Martin; Lyon is ~390 km away.
grant execute on all functions in schema pg_temp to authenticated;

create temp table ids as select
  pg_temp.person('Alex', 'woman', '{man}', 30, 48.8710, 2.3650) as alex,
  pg_temp.person('Leo', 'man', '{woman}', 32, 48.8600, 2.3500, array['cycling', 'running']) as leo,
  pg_temp.person('Maya', 'woman', '{}', 29, 48.8650, 2.3700) as maya,
  pg_temp.person('Noah', 'man', '{man}', 31, 48.8700, 2.3600) as noah,
  pg_temp.person('Tom', 'man', '{woman}', 33, 45.7640, 4.8357) as tom,
  pg_temp.person('Sam', 'man', '{}', 45, 48.8690, 2.3610) as sam;
grant select on ids to authenticated;

-- MARK: Signup and cards

select is((select count(*) from public.wallets w join ids on w.user_id = ids.alex), 1::bigint,
  'signup creates a wallet');

select is(
  (select jsonb_array_length(card -> 'media') from public.profile_cards, ids where user_id = ids.alex), 1,
  'approved media is on the card');

insert into public.profile_media (user_id, key, position, width, height)
  select alex, 'u/' || alex || '/photos/2.jpg', 1, 1200, 1600 from ids;
select is(
  (select jsonb_array_length(card -> 'media') from public.profile_cards, ids where user_id = ids.alex), 1,
  'pending media stays off the card');

select is(
  (select card -> 'sports' -> 0 ->> 'sport' from public.profile_cards, ids where user_id = ids.leo), 'cycling',
  'card lists sports in order');

select is((select sport_ids from public.profiles, ids where id = ids.leo), array['cycling', 'running'],
  'sport_ids is denormalized from profile_sports');

select ok((select card ? 'birthdate' from public.profile_cards, ids where user_id = ids.alex) is false,
  'birthdate never reaches the card');

select throws_ok(
  format($$insert into public.profile_media (user_id, key, position, width, height)
           values (%L, 'u/someone-else/photos/x.jpg', 5, 10, 10)$$, (select alex from ids)),
  '23514', null, 'media keys must sit under the owner prefix');

-- A refused photo can go back to review, once, by its owner only.
update public.profile_media set status = 'rejected' where key like 'u/' || (select alex from ids) || '/photos/2.jpg';
select pg_temp.login((select alex from ids));
select lives_ok(format('select public.request_media_review(%L)',
  (select id from public.profile_media where key like 'u/' || (select alex from ids) || '/photos/2.jpg')),
  'the owner asks for a second review');
select throws_ok(format('select public.request_media_review(%L)',
  (select id from public.profile_media where key like 'u/' || (select alex from ids) || '/photos/2.jpg')),
  'P0001', 'only your refused photos can be sent for review', 'a photo already in review cannot be sent again');

-- MARK: Discover

set local role authenticated;
select pg_temp.login((select alex from ids));

select ok((select leo from ids) = any (pg_temp.deck_ids('{"maxDistanceKm": 10}')), 'nearby match of preferences is shown');
select ok(not (select maya from ids) = any (pg_temp.deck_ids('{"maxDistanceKm": 10, "audience": ["man"]}')),
  'audience filter hides other genders');
select ok(not (select noah from ids) = any (pg_temp.deck_ids('{"maxDistanceKm": 10}')),
  'preferences are mutual: Noah only wants men');
select ok(not (select tom from ids) = any (pg_temp.deck_ids('{"maxDistanceKm": 50}')), 'distance limit applies');
select ok((select tom from ids) = any (pg_temp.deck_ids('{}')), 'no distance limit = any distance');
select ok(not (select sam from ids) = any (pg_temp.deck_ids('{"maxAge": 40}')), 'age filter applies');
select ok(not (select maya from ids) = any (pg_temp.deck_ids('{"sports": ["cycling"]}')), 'sport filter applies');
select ok(not (select alex from ids) = any (pg_temp.deck_ids('{}')), 'you never see yourself');
select ok(not (select maya from ids) = any (pg_temp.deck_ids('{}')), 'without an audience filter, your own preferences apply');
select is((select (c ->> 'distanceKm')::int from public.discover('{}') c, ids where (c ->> 'id')::uuid = ids.leo), 2,
  'distance is rounded to whole km');

reset role;
update public.wallets set super_likes = 1 where user_id = (select sam from ids);
select pg_temp.login((select sam from ids));
select public.swipe((select alex from ids), 'superlike', null, 'Coffee after?');
select pg_temp.login((select alex from ids));
set local role authenticated;
select is((select c ->> 'superLikeNote' from public.discover('{}') c limit 1), 'Coffee after?',
  'people who super liked you come first, with their note');

-- MARK: RLS

select is((select count(*) from public.profiles), 1::bigint, 'only your own profile row is readable');
select throws_ok('select * from private.locations', '42501', null, 'locations are not readable');

-- MARK: Swipes and matches

select is(public.swipe((select leo from ids), 'like') ->> 'matched', 'false', 'one-sided like is not a match');
select throws_ok(format('select public.swipe(%L, %L)', (select leo from ids), 'like'), 'P0001', 'already swiped',
  'a person can be swiped once');
select ok(not (select leo from ids) = any (pg_temp.deck_ids('{}')), 'swiped people leave the deck');
select throws_ok(format('select public.swipe(%L, %L)', (select maya from ids), 'superlike'), 'P0001',
  'no super likes left', 'super like needs a balance');

select pg_temp.login((select leo from ids));
select is((select count(*) from public.liked_me() c, ids where (c ->> 'id')::uuid = ids.alex), 1::bigint,
  'the like shows in their Likes');
select is(public.swipe((select alex from ids), 'like') ->> 'matched', 'true', 'mutual like is a match');
select is((select count(*) from public.my_matches()), 1::bigint, 'match is listed');

select pg_temp.login((select maya from ids));
select is((select count(*) from public.matches), 0::bigint, 'others cannot read the match');

-- MARK: Sessions

select pg_temp.login((select leo from ids));
create temp table s1 as
  select * from public.propose_session(
    (select id from public.matches limit 1),
    jsonb_build_object('sport', 'running', 'options', jsonb_build_array(now() + interval '2 days', now() + interval '3 days')));
select throws_ok(format('select public.respond_session(%L, true, %L)', (select id from s1), (select options[1] from s1)),
  'P0001', 'this session is not waiting for your answer', 'the proposer cannot accept their own session');

select pg_temp.login((select alex from ids));
select is((public.respond_session((select id from s1), true, (select options[2] from s1))).status, 'accepted',
  'the other person accepts one option');
select is((select count(*) from public.upcoming_sessions()), 1::bigint, 'accepted session is upcoming');

-- MARK: Blocking

select public.block_user((select leo from ids));
select is((select count(*) from public.my_matches()), 0::bigint, 'blocking ends the match');
select pg_temp.login((select leo from ids));
select ok(not (select alex from ids) = any (pg_temp.deck_ids('{}')), 'blocked people never see the blocker');

-- MARK: Privileges

-- Checked with has_*_privilege: calling a function without EXECUTE crashes the local Postgres image
-- (supabase/postgres 17.6.1.106, reproduced on an empty database).
reset role;
select ok(not has_function_privilege('anon', 'public.discover(jsonb, int)', 'execute'),
  'anonymous callers cannot use RPCs');
select ok(not has_function_privilege('authenticated', 'public.ack_event(bigint)', 'execute'),
  'only the server acks events');
select ok(not has_table_privilege('authenticated', 'public.wallets', 'update'),
  'wallets are not writable by clients');
select ok(has_table_privilege('service_role', 'public.profile_media', 'update')
          and has_table_privilege('service_role', 'public.matches', 'select'),
  'the Edge Functions (service role) can read and write tables');
set local role authenticated;

-- MARK: Events

reset role;
select ok((select count(*) from private.outbox where event in ('match.created', 'match.ended', 'session.accepted')) >= 3,
  'side effects are queued in the outbox');

select * from finish();
rollback;
