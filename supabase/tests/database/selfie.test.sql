-- The selfie hold: only the person uploads, only while asked, into their own folder; sending it moves the
-- account to review; lifting the hold queues the selfie's deletion.
begin;
create extension if not exists pgtap with schema extensions;
select plan(13);

create function pg_temp.person(p_email text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id)
  values (v_id, p_email, 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  return v_id;
end $$;

create function pg_temp.login(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

-- An upload as the storage API does it (the policy decides), true when it went in.
create function pg_temp.uploads(p_name text) returns boolean language plpgsql as $$
begin
  insert into storage.objects (bucket_id, name, owner_id) values ('verification-selfies', p_name, auth.uid()::text);
  return true;
exception when insufficient_privilege then
  return false;
end $$;

grant execute on all functions in schema pg_temp to authenticated;
create temp table ids as select pg_temp.person('sam@test.dev') as sam, pg_temp.person('eve@test.dev') as eve;
grant select on ids to authenticated;

select is((select public from storage.buckets where id = 'verification-selfies'), false, 'the bucket is private');

-- MARK: Not asked

set local role authenticated;
select pg_temp.login((select sam from ids));
select ok(not pg_temp.uploads((select sam from ids) || '/a.jpg'), 'no upload unless a selfie is asked for');
select throws_ok('select public.submit_selfie(''x'')', 'P0001', 'no selfie was asked for', 'nor a submission');

-- MARK: Asked

reset role;
select public.set_moderation((select sam from ids), 'selfie', 'photos look borrowed');
select is((select paused from public.profiles where id = (select sam from ids)), true, 'the hold freezes the profile');

set local role authenticated;
select pg_temp.login((select sam from ids));
select throws_ok('select public.discover()', 'P0001', 'your account is on hold', 'nothing else while asked');
select ok(not pg_temp.uploads((select eve from ids) || '/a.jpg'), 'not into someone else''s folder');
select ok(pg_temp.uploads((select sam from ids) || '/a.jpg'), 'into their own folder');
select is((select count(*) from storage.objects where bucket_id = 'verification-selfies'), 0::bigint,
  'and can''t read it back');
select throws_ok(format('select public.submit_selfie(%L)', (select sam from ids) || '/missing.jpg'),
  'P0001', 'selfie not found', 'only an uploaded selfie counts');
select lives_ok(format('select public.submit_selfie(%L)', (select sam from ids) || '/a.jpg'), 'sent');

reset role;
select is((select moderation::text from public.profiles where id = (select sam from ids)), 'review',
  'sending it moves the account to review');
select is((select note from private.moderation_log where user_id = (select sam from ids) order by id desc limit 1),
  'selfie sent', 'the team sees why');

select public.set_moderation((select sam from ids), null);
select is((select payload ->> 'userId' from private.outbox where event = 'selfie.delete' order by id desc limit 1),
  (select sam from ids)::text, 'lifting the hold deletes the selfie (db-events)');

select * from finish();
rollback;
