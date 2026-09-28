-- A paused profile is out of discovery: its owner can't swipe or browse, others can't reach it, until it
-- resumes. Sessions with current matches stay open (20260928000061); a hold still freezes them.
begin;
create extension if not exists pgtap with schema extensions;
select plan(18);

create function pg_temp.person(p_name text, p_km float8) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id)
  values (v_id, lower(p_name) || '@test.dev', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  update public.profiles
    set name = p_name, gender = 'woman', birthdate = current_date - make_interval(years => 30, days => 10)
    where id = v_id;
  insert into public.profile_sports (user_id, sport_id, per_week, position) values (v_id, 'running', 2, 0);
  insert into public.profile_media (user_id, key, position, width, height, status)
    values (v_id, 'u/' || v_id || '/photos/1.jpg', 0, 1200, 1600, 'approved');
  insert into private.locations (user_id, geo)
    values (v_id, extensions.st_setsrid(extensions.st_makepoint(2.35 + p_km / 73.2, 48.86), 4326)::extensions.geography);
  update public.profiles set onboarded_at = now() where id = v_id;
  return v_id;
end $$;

create function pg_temp.login(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

grant execute on all functions in schema pg_temp to authenticated;

create temp table ids as select
  pg_temp.person('Pia', 0) as pia, pg_temp.person('Ben', 1) as ben,
  pg_temp.person('Cleo', 2) as cleo, pg_temp.person('Dan', 3) as dan;
grant select on ids to authenticated;
update public.wallets set boosts = 1 where user_id = (select pia from ids);

-- Before the pause: Pia and Ben match and Ben proposes a session, Pia likes Dan, Cleo likes Pia.
set local role authenticated;
select pg_temp.login((select ben from ids));
select public.swipe((select pia from ids), 'like');
select pg_temp.login((select cleo from ids));
select public.swipe((select pia from ids), 'like');
select pg_temp.login((select pia from ids));
select public.swipe((select ben from ids), 'like');
select public.swipe((select dan from ids), 'like');
select pg_temp.login((select ben from ids));
create temp table s1 as
  select * from public.propose_session((select id from public.matches limit 1),
    jsonb_build_object('sport', 'running', 'options', jsonb_build_array(now() + interval '2 days')));

-- Pia pauses (the app writes the column directly).
select pg_temp.login((select pia from ids));
update public.profiles set paused = true where id = (select pia from ids);

-- MARK: The paused owner can't discover

select throws_ok(format('select public.swipe(%L, %L)', (select cleo from ids), 'like'), 'P0001',
  'your profile is paused, resume it first', 'no swiping');
select throws_ok('select public.undo_last_swipe()', 'P0001', 'your profile is paused, resume it first', 'no undo');
select throws_ok('select public.start_boost()', 'P0001', 'your profile is paused, resume it first', 'no boost');
select throws_ok('select public.discover()', 'P0001', 'your profile is paused, resume it first', 'no browsing');

-- MARK: The paused owner keeps planning sessions with their matches

create temp table s2 as
  select * from public.propose_session((select match_id from s1),
    jsonb_build_object('sport', 'running', 'options', jsonb_build_array(now() + interval '3 days')));
select is((select count(*) from s2), 1::bigint, 'proposing a session works while paused');
select lives_ok(format('select public.cancel_session(%L)', (select id from s2)), 'cancelling a session works while paused');
select lives_ok(format('select public.respond_session(%L, true, %L)', (select id from s1), (select options[1] from s1)),
  'answering a session works while paused');
select is((select count(*) from public.my_matches()), 1::bigint, 'matches stay readable');

-- MARK: Others can't reach them

select pg_temp.login((select dan from ids));
select throws_ok(format('select public.swipe(%L, %L)', (select pia from ids), 'like'), 'P0001',
  'profile not available', 'nobody can swipe on a paused profile');
select is((select count(*) from public.liked_me() c, ids where (c ->> 'id')::uuid = ids.pia), 0::bigint,
  'their likes leave the Likes tab');
select pg_temp.login((select ben from ids));
select lives_ok(format('select public.cancel_session(%L)', (select id from s1)),
  'the other person can still cancel their session');

-- MARK: Chat and resume

reset role;
select is((select payload from private.outbox where event = 'profile.paused' order by id desc limit 1),
  jsonb_build_object('userId', (select pia from ids), 'paused', true), 'pausing is sent to db-events (chat ban from holds only)');

set local role authenticated;
select pg_temp.login((select pia from ids));
select lives_ok(format('select public.block_user(%L)', (select dan from ids)), 'blocking stays possible');
update public.profiles set paused = false where id = (select pia from ids);
select is(public.swipe((select cleo from ids), 'like') ->> 'matched', 'true', 'resumed: swiping works again');

reset role;
select is((select payload ->> 'paused' from private.outbox where event = 'profile.paused' order by id desc limit 1),
  'false', 'resuming is sent too');

insert into public.swipes (swiper, target, action)
  select ben, dan, 'like' from ids;
update public.profiles set paused = true where id = (select ben from ids);
select throws_ok(format($$insert into public.swipes (swiper, target, action) values (%L, %L, 'like')$$,
    (select ben from ids), (select cleo from ids)),
  'P0001', 'your profile is paused, resume it first', 'the table itself refuses a paused swiper');


-- MARK: A hold still freezes sessions and swipes

reset role;
select public.set_moderation((select pia from ids), 'review');
set local role authenticated;
select pg_temp.login((select pia from ids));
select throws_ok(format('select public.propose_session(%L, %L)', (select match_id from s1),
    jsonb_build_object('sport', 'running', 'options', jsonb_build_array(now() + interval '4 days'))),
  'P0001', 'your account is on hold', 'no proposing a session on hold');
select throws_ok('select public.discover()', 'P0001', 'your account is on hold', 'no browsing on hold');
reset role;

select * from finish();
rollback;
