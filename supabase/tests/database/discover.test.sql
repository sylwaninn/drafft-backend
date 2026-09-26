-- Discover ranking: super likes, then boosts nearby, then a score of distance, activity, shared sports
-- and likes received. Activity from browsing and swiping keeps people in decks.
begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

-- A fully onboarded person open to everyone, `p_km` km east of the viewer (Paris), last active
-- `p_idle` ago.
create function pg_temp.person(
  p_name text, p_gender public.gender, p_km float8, p_idle interval default '0',
  p_sports text[] default array['yoga']
) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id)
  values (v_id, lower(p_name) || '@test.dev', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  update public.profiles
    set name = p_name, gender = p_gender, interested_in = '{}',
        birthdate = current_date - make_interval(years => 30, days => 10)
    where id = v_id;
  insert into public.profile_sports (user_id, sport_id, per_week, position)
    select v_id, s, 2, (o - 1)::smallint from unnest(p_sports) with ordinality as t(s, o);
  insert into public.profile_media (user_id, key, position, width, height, status)
    values (v_id, 'u/' || v_id || '/photos/1.jpg', 0, 1200, 1600, 'approved');
  -- ~73 km per degree of longitude at this latitude.
  insert into private.locations (user_id, geo)
    values (v_id, extensions.st_setsrid(extensions.st_makepoint(2.35 + p_km / 73.2, 48.86), 4326)::extensions.geography);
  update public.profiles set onboarded_at = now(), last_active_at = now() - p_idle where id = v_id;
  return v_id;
end $$;

create function pg_temp.login(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

create function pg_temp.deck(p_filters jsonb default '{}') returns text[] language sql as $$
  select coalesce(array_agg(c ->> 'name'), '{}') from public.discover(p_filters) c;
$$;

grant execute on all functions in schema pg_temp to authenticated;

create temp table ids as select
  pg_temp.person('Viewer', 'woman', 0, p_sports => array['running', 'cycling']) as viewer,
  pg_temp.person('Near', 'man', 1, interval '20 days') as near,
  pg_temp.person('Active', 'man', 4) as active,
  pg_temp.person('Sporty', 'man', 4, p_sports => array['running', 'cycling']) as sporty,
  pg_temp.person('Liker', 'man', 4, p_sports => array['running', 'cycling']) as liker,
  pg_temp.person('Gone', 'man', 1, interval '31 days') as gone,
  pg_temp.person('Faraway', 'man', 390) as faraway,
  pg_temp.person('Nowhere', 'man', 2) as nowhere;
grant select on ids to authenticated;
delete from private.locations where user_id = (select nowhere from ids);

-- MARK: Ranking

select pg_temp.login((select liker from ids));
select public.swipe((select viewer from ids), 'like');

select pg_temp.login((select viewer from ids));
set local role authenticated;

select is((pg_temp.deck('{"maxDistanceKm": 50}'))[1:4], array['Liker', 'Sporty', 'Active', 'Near'],
  'score: a like received, then shared sports, then activity beat a few km');
select ok(not 'Gone' = any (pg_temp.deck()), 'people gone for more than 30 days are hidden');
select is(pg_temp.deck('{}'), array['Liker', 'Sporty', 'Active', 'Near', 'Faraway'],
  'no distance limit: far people come last');

-- MARK: Boosts

reset role;
update public.wallets set boost_ends_at = now() + interval '10 minutes'
  where user_id in ((select faraway from ids), (select near from ids));
set local role authenticated;
select is((pg_temp.deck('{}'))[1], 'Near', 'a boost nearby puts you first');
select is((pg_temp.deck('{}'))[5], 'Faraway', 'a boost 390 km away does not, even with no distance limit');
select is((pg_temp.deck('{"maxDistanceKm": 500}'))[1:2], array['Near', 'Faraway'],
  'within the viewer''s own wider limit, it does');

reset role;
update public.wallets set boosts = 1 where user_id = (select nowhere from ids);
select pg_temp.login((select nowhere from ids));
select throws_ok('select public.start_boost()', 'P0001', 'your profile is hidden, nobody would see the boost',
  'a profile without a location cannot spend a boost');
select is((select boosts from public.wallets w, ids where w.user_id = ids.nowhere), 1, 'the boost is kept');

-- MARK: Super likes

update public.wallets set super_likes = 1 where user_id = (select active from ids);
select pg_temp.login((select active from ids));
select public.swipe((select viewer from ids), 'superlike');
select pg_temp.login((select viewer from ids));
set local role authenticated;
select is((pg_temp.deck('{}'))[1:2], array['Active', 'Near'], 'super likes come before boosts');

-- MARK: Activity

reset role;
update public.profiles set last_active_at = now() - interval '40 days' where id = (select viewer from ids);
update public.profiles set last_active_at = now() - interval '1 hour' where id = (select active from ids);
select pg_temp.login((select viewer from ids));
select pg_temp.deck();
select ok((select last_active_at from public.profiles, ids where id = ids.viewer) = now(), 'browsing counts as activity');
select pg_temp.login((select active from ids));
select public.swipe((select sporty from ids), 'pass');
select ok((select last_active_at from public.profiles, ids where id = ids.active) = now(), 'swiping counts as activity');

update public.profiles set last_active_at = now() - interval '2 minutes' where id = (select viewer from ids);
select pg_temp.login((select viewer from ids));
select pg_temp.deck();
select is((select last_active_at from public.profiles, ids where id = ids.viewer), now() - interval '2 minutes',
  'at most one write every 5 minutes');

-- MARK: Location

delete from private.locations where user_id = (select sporty from ids);
select pg_temp.login((select sporty from ids));
select throws_ok('select public.discover()', 'P0001', 'share your location to see people nearby',
  'no location: the app is told to ask for it');
select pg_temp.login((select viewer from ids));
select ok(not 'Sporty' = any (pg_temp.deck()), 'people without a location are not in decks');

select * from finish();
rollback;
