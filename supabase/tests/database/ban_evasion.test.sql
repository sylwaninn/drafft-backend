-- Coming back after a ban: normalised emails, digits-only phones, and the iPhone's DeviceCheck bit.
begin;
create extension if not exists pgtap with schema extensions;
select plan(18);

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

select public.set_moderation((select jo from ids), null);
select is((select payload ->> 'previous' from private.outbox where event = 'account.moderation' order by id desc limit 1),
  'banned', 'lifting a ban clears the device bit');

select ok(not has_function_privilege('authenticated', 'public.record_device_check(uuid, text, text)', 'execute')
    and not has_function_privilege('authenticated', 'public.device_flagged(uuid, boolean, boolean)', 'execute')
    and not has_function_privilege('authenticated', 'public.device_check_token(uuid)', 'execute'),
  'device functions are server-only');

select * from finish();
rollback;
