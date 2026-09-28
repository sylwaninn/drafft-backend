-- Likes left today (20260928000201): what swipe() still allows, for the app to show.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

create function pg_temp.person(p_name text, p_gender public.gender, p_interested public.gender[])
returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id)
  values (v_id, lower(p_name) || '@test.dev', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  update public.profiles
    set name = p_name, gender = p_gender, interested_in = p_interested,
        birthdate = current_date - make_interval(years => 30, days => 10), onboarded_at = now()
    where id = v_id;
  return v_id;
end $$;

create function pg_temp.login(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

grant execute on all functions in schema pg_temp to authenticated;

create temp table ids as select
  pg_temp.person('Ava', 'woman', '{man}') as ava,
  pg_temp.person('Max', 'man', '{woman}') as max,
  pg_temp.person('Leo', 'man', '{woman}') as leo,
  pg_temp.person('Tom', 'man', '{woman}') as tom;
grant select on ids to authenticated;

-- An old like (out of the window), a recent like, a pass and a super like: only the recent like counts.
insert into public.swipes (swiper, target, action, created_at) values
  ((select ava from ids), (select max from ids), 'like', now() - interval '25 hours'),
  ((select ava from ids), (select leo from ids), 'like', now() - interval '2 hours'),
  ((select ava from ids), (select tom from ids), 'pass', now() - interval '1 hour');

select ok(has_function_privilege('authenticated', 'public.likes_left()', 'execute'), 'signed-in people can call it');
select ok(not has_function_privilege('anon', 'public.likes_left()', 'execute'), 'signed-out callers cannot');

set local role authenticated;
select pg_temp.login((select ava from ids));
select is((public.likes_left() ->> 'left')::int, 19, 'only likes of the last 24 hours count');
select is((public.likes_left() ->> 'limit')::int, 20, 'the limit swipe() applies');
select ok((public.likes_left() ->> 'nextAt')::timestamptz between now() + interval '21 hours' and now() + interval '23 hours',
  'the oldest like of the window frees a like 24 hours after it');

select pg_temp.login((select max from ids));
select is(public.likes_left(), '{"unlimited": false, "limit": 20, "left": 20, "nextAt": null}'::jsonb, 'no like yet: all 20');

reset role;
update public.wallets set premium_until = now() + interval '1 month' where user_id = (select ava from ids);
set local role authenticated;
select pg_temp.login((select ava from ids));
select is(public.likes_left(), '{"unlimited": true}'::jsonb, 'drafft tempo: unlimited');

select * from finish();
rollback;
