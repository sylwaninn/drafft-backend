-- The app's rules enforced by the database (20260928000002): onboarding before Discover, swipes and boosts,
-- likes only to people who want to see the liker, reports from onboarded accounts with no hold and a daily
-- limit, and no new media or push token for an account on hold.
begin;
create extension if not exists pgtap with schema extensions;
select plan(24);

create function pg_temp.person(
  p_name text, p_gender public.gender, p_interested public.gender[], p_onboarded boolean default true
) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id)
  values (v_id, lower(p_name) || '@test.dev', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  update public.profiles
    set name = p_name, gender = p_gender, interested_in = p_interested,
        birthdate = current_date - make_interval(years => 30, days => 10)
    where id = v_id;
  insert into public.profile_sports (user_id, sport_id, per_week, position) values (v_id, 'running', 2, 0);
  insert into public.profile_media (user_id, key, position, width, height, status)
    values (v_id, 'u/' || v_id || '/photos/1.jpg', 0, 1200, 1600, 'approved');
  insert into private.locations (user_id, geo)
    values (v_id, extensions.st_setsrid(extensions.st_makepoint(2.35, 48.86), 4326)::extensions.geography);
  if p_onboarded then
    update public.profiles set onboarded_at = now() where id = v_id;
  end if;
  return v_id;
end $$;

create function pg_temp.login(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

grant execute on all functions in schema pg_temp to authenticated;

create temp table ids as select
  pg_temp.person('Nina', 'woman', '{man}', false) as nina,     -- never finished onboarding
  pg_temp.person('Ava', 'woman', '{man}') as ava,
  pg_temp.person('Max', 'man', '{woman}') as max,
  pg_temp.person('Zoe', 'woman', '{woman}') as zoe,            -- only wants to see women
  pg_temp.person('Hugo', 'man', '{woman}') as hugo,            -- will be on hold
  pg_temp.person('Paul', 'man', '{woman}') as paul,            -- will be paused
  pg_temp.person('Tia', 'woman', '{}') as tia;
grant select on ids to authenticated;
update public.wallets set boosts = 1 where user_id = (select nina from ids);

-- MARK: Onboarding first

set local role authenticated;
select pg_temp.login((select nina from ids));
select throws_ok('select public.discover()', 'P0001', 'finish your profile first', 'no Discover before onboarding');
select throws_ok(format('select public.swipe(%L, %L)', (select max from ids), 'like'), 'P0001',
  'finish your profile first', 'no like before onboarding');
select throws_ok('select public.undo_last_swipe()', 'P0001', 'finish your profile first', 'no undo before onboarding');
select throws_ok('select public.start_boost()', 'P0001', 'finish your profile first', 'no boost before onboarding');
select throws_ok(format('select public.report_user(%L, %L)', (select max from ids), 'spam'), 'P0001',
  'finish your profile first', 'no report before onboarding');

-- MARK: Likes reach people who want to see the liker

select pg_temp.login((select max from ids));
select throws_ok(format('select public.swipe(%L, %L)', (select zoe from ids), 'like'), 'P0001',
  'this person is not looking for you', 'no like to someone whose preferences leave you out');
select throws_ok(format('select public.swipe(%L, %L)', (select zoe from ids), 'superlike'), 'P0001',
  'this person is not looking for you', 'no super like either');
select lives_ok(format('select public.swipe(%L, %L)', (select zoe from ids), 'pass'), 'a pass is always possible');
select lives_ok(format('select public.swipe(%L, %L)', (select ava from ids), 'like'), 'a like within preferences');
select lives_ok(format('select public.swipe(%L, %L)', (select tia from ids), 'like'), 'no preference: open to all');

-- Zoe likes Hugo, outside her own preferences: Hugo can still answer her like.
reset role;
insert into public.swipes (swiper, target, action) select zoe, hugo, 'like' from ids;
set local role authenticated;
select pg_temp.login((select hugo from ids));
select lives_ok(format('select public.swipe(%L, %L)', (select zoe from ids), 'like'), 'answering a like is possible');
select is((select count(*) from public.matches, ids where user_a = least(zoe, hugo) and user_b = greatest(zoe, hugo)),
  1::bigint, 'and makes the match');

-- MARK: Reports

select pg_temp.login((select ava from ids));
select lives_ok(format('select public.report_user(%L, %L)', (select max from ids), 'spam'), 'an onboarded member reports');
reset role;
-- Nine more reports today reach the limit.
insert into public.reports (reporter, reported, reason) select ava, tia, 'spam' from ids, generate_series(1, 9);
set local role authenticated;
select pg_temp.login((select ava from ids));
select throws_ok(format('select public.report_user(%L, %L)', (select paul from ids), 'spam'), 'P0001',
  'too many reports today, contact us instead', 'at most 10 reports in 24 hours');

-- A paused member can still report (docs/matching.md, Pause).
select pg_temp.login((select paul from ids));
update public.profiles set paused = true where id = (select paul from ids);
select lives_ok(format('select public.report_user(%L, %L)', (select ava from ids), 'harassment'),
  'a paused member can still report');

-- An account on hold can't.
reset role;
update public.profiles set moderation = 'review' where id = (select hugo from ids);
set local role authenticated;
select pg_temp.login((select hugo from ids));
select throws_ok(format('select public.report_user(%L, %L)', (select tia from ids), 'underage'), 'P0001',
  'your account is on hold', 'no report from an account on hold');

-- Reports that don't come from an onboarded account with no hold never hold anyone by themselves.
reset role;
insert into public.reports (reporter, reported, reason) select nina, max, 'underage' from ids;
insert into public.reports (reporter, reported, reason) select hugo, max, 'underage' from ids;
select is((select moderation::text from public.profiles where id = (select max from ids)), null,
  'underage reports from unqualified accounts hold nobody');
insert into public.reports (reporter, reported, reason) select tia, max, 'underage' from ids;
select is((select moderation::text from public.profiles where id = (select max from ids)), 'review',
  'the same report from an onboarded member still holds at once');
select is((select count(*) from public.reports, ids where reported = max), 4::bigint, 'every report is kept for the team');

-- MARK: Account on hold

set local role authenticated;
select pg_temp.login((select hugo from ids));
select throws_ok(format($$select public.add_profile_media('u/%s/photos/2.jpg', 10, 10)$$, (select hugo from ids)),
  'P0001', 'your account is on hold', 'no new media on hold');
select throws_ok($$select public.register_push_token('tok-hugo', 'production')$$, 'P0001', 'your account is on hold',
  'no push token on hold');
select lives_ok('select public.request_data_export()', 'the data export stays open on hold');

select pg_temp.login((select paul from ids));
select lives_ok(format($$select public.add_profile_media('u/%s/photos/2.jpg', 10, 10)$$, (select paul from ids)),
  'a paused member still edits their photos');
select lives_ok($$select public.register_push_token('tok-paul', 'production')$$, 'a paused member keeps notifications');

select * from finish();
rollback;
