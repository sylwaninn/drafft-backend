-- Push tokens by platform (20261001000101): the Android app says it's Android, an iPhone build that sends
-- no platform is recognised by its token, a token that moves to another account keeps its platform right,
-- and FCM is a provider with its own circuit, listed by every event that pushes.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

create function pg_temp.person(p_name text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id)
  values (v_id, lower(p_name) || '@test.dev', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  return v_id;
end $$;

create function pg_temp.login(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

grant execute on all functions in schema pg_temp to authenticated;

create temp table ids as select pg_temp.person('Ana') as ana, pg_temp.person('Bo') as bo;
grant select on ids to authenticated;

set local role authenticated;
select pg_temp.login((select ana from ids));
select lives_ok($$select public.register_push_token('fcm-token:APA91b' || repeat('x', 150), 'production', 'android')$$,
  'the Android app registers its FCM token');
select lives_ok($$select public.register_push_token(repeat('ab', 32), 'sandbox')$$,
  'an iPhone build without the platform still registers');
select pg_temp.login((select bo from ids));
select lives_ok($$select public.register_push_token('fcm-old:legacy', 'production')$$,
  'an Android build without the platform still registers');
reset role;

select is((select platform from public.push_tokens where token like 'fcm-token:%'), 'android', 'sent platform kept');
select is((select platform from public.push_tokens where token = repeat('ab', 32)), 'ios', 'a 64-hex token is an iPhone');
select is((select platform from public.push_tokens where token = 'fcm-old:legacy'), 'android', 'anything else is Android');

select is(
  (select count(*) from private.outbox_policies where 'apns' = any (providers) and not 'fcm' = any (providers)),
  0::bigint, 'every event that pushes through APNs pushes through FCM too'
);

select * from finish();
rollback;
