-- A hold follows the person: a new account with the email, phone, Apple/Google sign-in or iPhone of an
-- account on hold starts with that hold, the strictest still pending; lifting it frees every identity.
begin;
create extension if not exists pgtap with schema extensions;
select plan(16);

create function pg_temp.person(p_email text, p_phone text default null) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, phone, aud, role, instance_id)
  values (v_id, p_email, p_phone, 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  return v_id;
end $$;

create function pg_temp.sign_in_with(p_user uuid, p_provider text, p_sub text) returns void language sql as $$
  insert into auth.identities (provider_id, user_id, identity_data, provider) values (p_sub, p_user, '{}'::jsonb, p_provider);
$$;

create function pg_temp.hold(p_user uuid) returns text language sql as $$
  select moderation::text from public.profiles where id = p_user;
$$;

-- MARK: Same email, after deleting the account

create temp table a as select pg_temp.person('Alex.Rivers@gmail.com', '33700000001') as id;
select public.set_moderation((select id from a), 'selfie', 'photos look borrowed');
select ok((select bool_and(hash !~ '@' and char_length(hash) = 64) from private.identity_marks), 'marks are digests, never in clear');
delete from auth.users where id = (select id from a);

create temp table b as select pg_temp.person('alexrivers+new@googlemail.com') as id;
select is(pg_temp.hold((select id from b)), 'selfie', 'a new account with the same email owes the selfie');
select is((select note from private.moderation_log where user_id = (select id from b) order by id desc limit 1),
  'carried over: same email as an account on hold', 'the team sees why');
select is((select count(*) from private.identity_marks where user_id = (select id from b) and kind = 'phone'), 1::bigint,
  'it takes over the old account''s phone too');

-- Sending the selfie doesn't settle it for a next account: the selfie goes with a deleted account.
select public.set_moderation((select id from b), 'review', 'selfie sent');
select is((select state::text from private.identity_marks where user_id = (select id from b) and kind = 'email'),
  'selfie', 'a selfie owed stays owed');

-- Lifted: every identity is free again, the old phone included.
select public.set_moderation((select id from b), null);
select is((select count(*) from private.identity_marks where user_id in ((select id from a), (select id from b))),
  0::bigint, 'lifting frees every identity');
create temp table c as select pg_temp.person('carol@test.dev') as id;
update auth.users set phone = '33700000001' where id = (select id from c);
select is(pg_temp.hold((select id from c)), null, 'the old phone no longer carries anything');

-- MARK: Same phone, verified after sign-up

create temp table d as select pg_temp.person('dana@test.dev', '33700000002') as id;
select public.set_moderation((select id from d), 'review');
delete from auth.users where id = (select id from d);
create temp table e as select pg_temp.person('erin@test.dev') as id;
select is(pg_temp.hold((select id from e)), null, 'a new email alone carries nothing');
update auth.users set phone = '+33 7 00 00 00 02' where id = (select id from e);
select is(pg_temp.hold((select id from e)), 'review', 'verifying the phone brings the review back');

-- MARK: Apple and Google sign-ins

create temp table f as select pg_temp.person('f@privaterelay.appleid.com') as id;
select pg_temp.sign_in_with((select id from f), 'google', 'google-sub-1');
select public.set_moderation((select id from f), 'selfie');
delete from auth.users where id = (select id from f);
create temp table g as select pg_temp.person('other@test.dev') as id;
select pg_temp.sign_in_with((select id from g), 'google', 'google-sub-1');
select is(pg_temp.hold((select id from g)), 'selfie', 'the same Google account carries the hold');

create temp table h as select pg_temp.person('h@test.dev') as id;
select pg_temp.sign_in_with((select id from h), 'apple', 'apple-sub-1');
select public.set_moderation((select id from h), 'banned');
delete from auth.users where id = (select id from h);
create temp table i as select pg_temp.person('i@test.dev') as id;
select throws_ok(format($$select pg_temp.sign_in_with(%L, 'apple', 'apple-sub-1')$$, (select id from i)),
  'P0001', 'this account can no longer be used on drafft', 'a banned Apple ID can''t sign in again');

-- MARK: A ban closes every mark

create temp table j as select pg_temp.person('j@test.dev', '33700000003') as id;
select public.set_moderation((select id from j), 'review');
select public.set_moderation((select id from j), 'banned');
select is((select count(*) from private.identity_marks where user_id = (select id from j) and state <> 'banned'),
  0::bigint, 'a ban replaces the hold on every identity');

-- MARK: The iPhone

create temp table k as select pg_temp.person('k@test.dev') as id;
select is(public.record_device_check((select id from k), repeat('k', 40), 'production'), 'check', 'a new account reads its bits');
select public.device_flagged((select id from k), false, true);
select is(pg_temp.hold((select id from k)), 'selfie', 'an iPhone with an account on hold means a selfie');
select is((select note from private.moderation_log where user_id = (select id from k) order by id desc limit 1),
  'device of an account on hold', 'with the reason');

select is((select payload ->> 'previous' from private.outbox where event = 'account.moderation' order by id desc limit 1),
  null, 'every change goes to db-events (bits and emails)');

select * from finish();
rollback;
