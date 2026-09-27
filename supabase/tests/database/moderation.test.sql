-- A moderation hold freezes an account like a pause its owner can't lift; a ban also keeps its email
-- and phone from signing up again.
begin;
create extension if not exists pgtap with schema extensions;
select plan(20);

create function pg_temp.person(p_name text, p_phone text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, phone, aud, role, instance_id)
  values (v_id, p_name || '@Test.dev', p_phone, 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  update public.profiles
    set name = p_name, gender = 'woman', birthdate = current_date - make_interval(years => 30, days => 10)
    where id = v_id;
  insert into public.profile_sports (user_id, sport_id, per_week, position) values (v_id, 'running', 2, 0);
  insert into public.profile_media (user_id, key, position, width, height, status)
    values (v_id, 'u/' || v_id || '/photos/1.jpg', 0, 1200, 1600, 'approved');
  insert into private.locations (user_id, geo)
    values (v_id, extensions.st_setsrid(extensions.st_makepoint(2.35, 48.86), 4326)::extensions.geography);
  update public.profiles set onboarded_at = now() where id = v_id;
  return v_id;
end $$;

create function pg_temp.login(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

grant execute on all functions in schema pg_temp to authenticated;

create temp table ids as select pg_temp.person('Mia', '33611111111') as mia, pg_temp.person('Ned', '33622222222') as ned;
grant select on ids to authenticated;

-- MARK: Only the team sets it

set local role authenticated;
select pg_temp.login((select mia from ids));
select throws_ok(format($$update public.profiles set moderation = 'review' where id = %L$$, (select mia from ids)),
  '42501', null, 'the owner can''t set a hold');
select ok(not has_function_privilege('authenticated', 'public.set_moderation(uuid, public.moderation_state, text)',
  'execute'), 'nor call the dashboard function');

-- MARK: Review

reset role;
select public.set_moderation((select mia from ids), 'review', 'reported twice');
select is((select paused from public.profiles where id = (select mia from ids)), true, 'a hold pauses the profile');
select is((select note from private.moderation_log where user_id = (select mia from ids) order by id desc limit 1),
  'reported twice', 'the note is logged');
select is((select payload ->> 'paused' from private.outbox where event = 'profile.paused' order by id desc limit 1),
  'true', 'chats freeze (Stream ban)');

set local role authenticated;
select pg_temp.login((select mia from ids));
select is((select moderation::text from public.profiles where id = (select mia from ids)), 'review', 'the owner reads it');
select throws_ok('select public.discover()', 'P0001', 'your account is on hold', 'no browsing');
select throws_ok(format($$select public.swipe(%L, 'like')$$, (select ned from ids)),
  'P0001', 'your account is on hold', 'no swiping');
select throws_ok(format($$update public.profiles set paused = false where id = %L$$, (select mia from ids)),
  'P0001', 'your account is on hold', 'no resuming while held');
select pg_temp.login((select ned from ids));
select is((select count(*) from public.discover()), 0::bigint, 'hidden from others');

-- MARK: Lifted

reset role;
select public.set_moderation((select mia from ids), null);
select is((select paused from public.profiles where id = (select mia from ids)), false, 'lifting gives the pause back');
select is((select count(*) from private.moderation_holds where user_id = (select mia from ids)), 0::bigint,
  'nothing left held');

-- A person who had paused stays paused.
update public.profiles set paused = true where id = (select mia from ids);
select public.set_moderation((select mia from ids), 'review');
select public.set_moderation((select mia from ids), null);
select is((select paused from public.profiles where id = (select mia from ids)), true, 'their own pause is kept');

-- MARK: Banned

select public.set_moderation((select mia from ids), 'banned');
select is((select array_agg(kind order by kind) from private.identity_marks
    where user_id = (select mia from ids) and state = 'banned'),
  array['email', 'phone'], 'email and phone are banned');
select throws_ok($$insert into auth.users (id, email, aud, role, instance_id)
    values (gen_random_uuid(), 'MIA@test.dev', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000')$$,
  'P0001', 'this account can no longer be used on drafft', 'no new account with the email');
select throws_ok(format($$update auth.users set phone = '33611111111' where id = %L$$, (select ned from ids)),
  'P0001', 'this account can no longer be used on drafft', 'nor moving the phone to another account');
select lives_ok(format($$update auth.users set email = email, phone = phone, last_sign_in_at = now() where id = %L$$,
    (select mia from ids)), 'the banned account still signs in, to see why');

delete from auth.users where id = (select mia from ids);
select throws_ok($$insert into auth.users (id, email, aud, role, instance_id)
    values (gen_random_uuid(), 'mia@test.dev', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000')$$,
  'P0001', 'this account can no longer be used on drafft', 'deleting the account doesn''t clear the ban');

-- Unbanning (a mistake) clears them.
select public.set_moderation((select ned from ids), 'banned');
select public.set_moderation((select ned from ids), null);
select is((select count(*) from private.identity_marks where user_id = (select ned from ids)), 0::bigint,
  'lifting a ban frees the email and phone');

select throws_ok(format($$select public.set_moderation(%L, 'review')$$, gen_random_uuid()),
  'P0001', 'no such account', 'unknown accounts are refused');

select * from finish();
rollback;
