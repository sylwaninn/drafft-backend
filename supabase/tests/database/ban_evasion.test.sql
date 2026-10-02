-- Coming back after a ban: normalised emails, digits-only phones, and the device's bits (DeviceCheck, Play Integrity).
begin;
create extension if not exists pgtap with schema extensions;
select plan(42);

create function pg_temp.person(p_email text, p_phone text default null) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, phone, aud, role, instance_id)
  values (v_id, p_email, p_phone, 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  return v_id;
end $$;

create function pg_temp.signs_up(p_email text, p_phone text default null) returns boolean language plpgsql as $$
begin
  perform pg_temp.person(p_email, p_phone);
  return true;
exception when others then
  return false;
end $$;

-- MARK: Normalised emails

select is(private.normalize_email(' Jo.Doe+runs@GoogleMail.com '), 'jodoe@gmail.com', 'gmail: case, dots, tag, domain');
select is(private.normalize_email('jo.doe+x@outlook.com'), 'jo.doe@outlook.com', 'others: only the tag goes');
select is(private.normalize_email('jo@mac.com'), 'jo@icloud.com', 'me.com and mac.com are icloud.com');
select is(private.normalize_phone('+33 6 12 34 56 78'), '33612345678', 'phones: digits only');

create temp table ids as select pg_temp.person('Jo.Doe@gmail.com', '33612345678') as jo, pg_temp.person('ann@test.dev') as ann;
select public.set_moderation((select jo from ids), 'banned');

select is((select hash from private.identity_marks where kind = 'email' and user_id = (select jo from ids)),
  private.identity_hash('email', 'jodoe@gmail.com'), 'the ban keeps the normalised email, digested');
select ok(not pg_temp.signs_up('jodoe+again@gmail.com'), 'no sign-up with a tag');
select ok(not pg_temp.signs_up('J.O.D.O.E@googlemail.com'), 'nor with dots or googlemail');
select ok(pg_temp.signs_up('jodoe@yahoo.com'), 'another mailbox still signs up');
select ok(not pg_temp.signs_up('someone@test.dev', '33612345678'), 'nor with the phone');

-- MARK: DeviceCheck

select is((select payload ->> 'state' from private.outbox where event = 'account.moderation' order by id desc limit 1),
  'banned', 'a ban sets the device bit (db-events)');
select is(public.record_device_check((select jo from ids), repeat('t', 40), 'production'), 'ban',
  'a closed account opening the app sets it again');

select is(public.record_device_check((select ann from ids), repeat('a', 40), 'development'), 'check',
  'an account in good standing reads its bits');
select public.device_flagged((select ann from ids), true, false);
select is((select moderation::text from public.profiles where id = (select ann from ids)), 'review',
  'a flagged iPhone sends the account to review');
select is((select note from private.moderation_log where user_id = (select ann from ids) order by id desc limit 1),
  'device used by a closed account', 'with the reason for the team');
select is(public.record_device_check((select ann from ids), repeat('b', 40), 'development'), 'hold',
  'held: the iPhone gets bit1');

select public.set_moderation((select ann from ids), null);
select is(public.record_device_check((select ann from ids), repeat('c', 40), 'development'), 'none',
  'cleared by the team: never flagged again (second-hand iPhone)');

-- MARK: Play Integrity

select is(public.record_device_check((select ann from ids), repeat('p', 900), 'production', 'android'), 'none',
  'an Android device is recorded like an iPhone, and a flagged account stays flagged across platforms');
select is((select platform from private.device_checks where user_id = (select ann from ids)), 'android',
  'with its platform');
select is((select environment || '/' || platform from public.device_check_token((select ann from ids))),
  'production/android', 'db-events reads the platform and the environment');
select ok((select updated_at > now() - interval '1 minute' from public.device_check_token((select ann from ids))),
  'and when the token was stored');
select ok((select flagged_at is not null from private.device_checks where user_id = (select ann from ids)),
  'a platform change keeps flagged_at, so the device is never flagged twice');

select lives_ok($$select public.record_device_check((select ann from ids), repeat('x', 16384), 'production', 'android')$$,
  'a Play Integrity token of 16 KB is stored');
select throws_ok($$select public.record_device_check((select ann from ids), repeat('x', 16385), 'production', 'android')$$,
  '23514', null, 'a larger one is refused');
select throws_ok($$select public.record_device_check((select ann from ids), repeat('x', 19), 'production', 'android')$$,
  '23514', null, 'and a token too short to be one');
select throws_ok($$select public.record_device_check((select ann from ids), repeat('x', 40), 'production', 'windows')$$,
  '23514', null, 'a platform other than ios and android is refused');

select is(public.record_device_check((select ann from ids), repeat('q', 40), 'production'), 'none',
  'the iPhone builds still send no platform');
select is((select platform from private.device_checks where user_id = (select ann from ids)), 'ios',
  'which then reads ios');
select is(public.record_device_check((select ann from ids), repeat('q', 40), 'production', null), 'none',
  'a null platform is an iPhone too');

update private.device_checks set updated_at = now() - interval '20 days' where user_id = (select ann from ids);
select public.record_device_check((select ann from ids), repeat('r', 40), 'production', 'android');
select ok((select updated_at > now() - interval '1 day' from private.device_checks where user_id = (select ann from ids)),
  'a new token renews updated_at, which the 14-day write window counts from');

-- MARK: Device check calls

select is((select standing from public.device_check_begin((select ann from ids))), 'ok', 'an account in good standing');
select ok((select verified_at is not null from public.device_check_begin((select ann from ids))),
  'with its Android token verified');
select is((select standing from public.device_check_begin((select jo from ids))), 'banned', 'a closed account');
select public.set_moderation((select ann from ids), 'review');
select is((select standing from public.device_check_begin((select ann from ids))), 'held', 'an account on hold');
select public.set_moderation((select ann from ids), null);

select is((select has_pending from public.device_check_begin((select ann from ids))), false, 'nothing waits');
select public.device_check_set_pending((select ann from ids), true, null);
select is((select has_pending from public.device_check_begin((select ann from ids))), true, 'a change that couldn''t be written waits');
select public.device_check_set_pending((select ann from ids), null, false);
select results_eq($$select bit0, bit1 from public.device_check_take_pending((select ann from ids))$$,
  $$values (true, false)$$, 'a later change to the other bit adds to it');
select results_eq($$select bit0, bit1 from public.device_check_take_pending((select ann from ids))$$,
  $$values (null::boolean, null::boolean)$$, 'taking it clears it');
select is((select has_pending from public.device_check_begin((select ann from ids))), false, 'nothing waits again');

create temp table calm as select pg_temp.person('calm@test.dev') as bo;
select public.device_check_begin((select bo from calm)) from generate_series(1, 20);
select throws_ok($$select public.device_check_begin((select bo from calm))$$, 'P0001',
  'too many device checks, try again later', 'an account checks 20 times an hour, no more');

select public.set_moderation((select jo from ids), null);
select is((select payload ->> 'previous' from private.outbox where event = 'account.moderation' order by id desc limit 1),
  'banned', 'lifting a ban clears the device bit');

select ok(not has_function_privilege('authenticated', 'public.record_device_check(uuid, text, text, text)', 'execute')
    and not has_function_privilege('authenticated', 'public.device_flagged(uuid, boolean, boolean)', 'execute')
    and not has_function_privilege('authenticated', 'public.device_check_token(uuid)', 'execute')
    and not has_function_privilege('authenticated', 'public.device_check_begin(uuid)', 'execute')
    and not has_function_privilege('authenticated', 'public.device_check_set_pending(uuid, boolean, boolean)', 'execute')
    and not has_function_privilege('authenticated', 'public.device_check_take_pending(uuid)', 'execute')
    and not has_function_privilege('anon', 'public.device_check_begin(uuid)', 'execute'),
  'device functions are server-only');
select hasnt_function('public', 'record_device_check', array['uuid', 'text', 'text'],
  'the three-argument version is gone: no overload to call by mistake');

select * from finish();
rollback;
