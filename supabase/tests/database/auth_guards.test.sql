-- Sign-up guards: verification SMS limits and reservations (phone-code, auth-sms), a finished onboarding
-- needs a confirmed email and phone, and deleted Auth sessions are announced on the person's topic.
begin;
create extension if not exists pgtap with schema extensions;
select plan(19);

create function pg_temp.person(p_email text, p_email_ok boolean, p_phone text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id, email_confirmed_at, phone, phone_confirmed_at)
  values (v_id, p_email, 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000',
    case when p_email_ok then now() end, p_phone, case when p_phone is not null then now() end);
  return v_id;
end $$;

create temp table ids as select
  pg_temp.person('ana@test.dev', true, null) as ana,
  pg_temp.person('ben@test.dev', true, null) as ben,
  pg_temp.person('cy@test.dev', false, null) as cy,
  pg_temp.person('dee@test.dev', true, '33612345678') as dee,
  pg_temp.person('eve@test.dev', true, null) as eve;
grant select on ids to authenticated;

-- MARK: Reservations

select throws_ok(format($$select public.reserve_sms(%L, '0612345678', null)$$, (select ana from ids)),
  'P0001', 'not a phone number', 'a number that is not E.164 is refused');
select is(public.consume_sms((select ana from ids), '+33611111111'), false, 'no reservation: the hook sends nothing');

create temp table r as select public.reserve_sms((select ana from ids), '+33611111111', '203.0.113.7') as id;
select is(public.consume_sms((select ana from ids), '+33611111111'), false, 'not approved by Lookup: nothing sent');
select public.approve_sms((select id from r));
select is(public.consume_sms((select ben from ids), '+33611111111'), false, 'another account cannot use it');
select is(public.consume_sms((select ana from ids), '+33622222222'), false, 'nor another number');
select is(public.consume_sms((select ana from ids), '+33611111111'), true, 'approved: sent once');
select is(public.consume_sms((select ana from ids), '+33611111111'), false, 'and only once');

update r set id = public.reserve_sms((select ana from ids), '+33611111111', 'not an ip');
select public.approve_sms((select id from r));
update private.sms_sends set approved_at = now() - interval '11 minutes' where id = (select id from r);
select is(public.consume_sms((select ana from ids), '+33611111111'), false, 'older than 10 minutes: expired');
select is((select ip from private.sms_sends where id = (select id from r)), null::inet, 'an unreadable IP is stored as none');

-- MARK: Limits

select public.reserve_sms((select ana from ids), '+33611111111', null);
select throws_ok(format($$select public.reserve_sms(%L, '+33611111111', null)$$, (select ben from ids)),
  'P0001', 'too many codes, try again later', 'per number: 3 an hour, whichever account asks');
update private.sms_sends set created_at = now() - interval '2 hours' where phone = '+33611111111';
select public.reserve_sms((select ana from ids), '+33611111111', null) from generate_series(1, 3);
update private.sms_sends set created_at = now() - interval '2 hours' where phone = '+33611111111';
select throws_ok(format($$select public.reserve_sms(%L, '+33611111111', null)$$, (select ben from ids)),
  'P0001', 'too many codes, try again later', 'per number: 6 a day');

select public.reserve_sms((select eve from ids), '+3363000000' || i, null) from generate_series(1, 5) i;
select throws_ok(format($$select public.reserve_sms(%L, '+33640000000', null)$$, (select eve from ids)),
  'P0001', 'too many codes, try again later', 'per account: 5 an hour');

select public.reserve_sms((select ben from ids), '+3365000000' || i, '198.51.100.1') from generate_series(1, 5) i;
update private.sms_sends set user_id = null where ip = '198.51.100.1';
select public.reserve_sms((select ben from ids), '+3366000000' || i, '198.51.100.1') from generate_series(1, 5) i;
select throws_ok(format($$select public.reserve_sms(%L, '+33670000000', '198.51.100.1')$$, (select dee from ids)),
  'P0001', 'too many codes, try again later', 'per IP: 10 an hour, across accounts');
select lives_ok(format($$select public.reserve_sms(%L, '+33670000000', '198.51.100.2')$$, (select dee from ids)),
  'another IP is not held back');

select ok(not has_function_privilege('authenticated', 'public.reserve_sms(uuid, text, text)', 'execute')
  and not has_function_privilege('anon', 'public.consume_sms(uuid, text)', 'execute')
  and not has_function_privilege('authenticated', 'public.approve_sms(bigint)', 'execute'),
  'the reservations are server-side only');

-- MARK: Onboarding

insert into public.profiles (id) select id from auth.users where id in ((select cy from ids), (select ana from ids))
  on conflict do nothing;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', (select cy from ids), 'role', 'authenticated')::text, true);
select throws_ok('select public.complete_onboarding()', 'P0001', 'confirm your email first',
  'an unconfirmed email cannot finish sign-up');
select set_config('request.jwt.claims', json_build_object('sub', (select ana from ids), 'role', 'authenticated')::text, true);
select throws_ok('select public.complete_onboarding()', 'P0001', 'verify your phone number first',
  'no confirmed phone number: phone_required');
reset role;

-- MARK: Revoked sessions

insert into auth.sessions (id, user_id) values
  ('00000000-0000-0000-0000-00000000a001', (select dee from ids)),
  ('00000000-0000-0000-0000-00000000a002', (select dee from ids));
delete from auth.sessions where user_id = (select dee from ids);
select is((select payload -> 'sessions' from realtime.messages
            where topic = 'user:' || (select dee from ids)::text and event = 'session_revoked'),
  '["00000000-0000-0000-0000-00000000a001", "00000000-0000-0000-0000-00000000a002"]'::jsonb,
  'deleting sessions broadcasts session_revoked with their ids, once per person');
select is((select private from realtime.messages where topic = 'user:' || (select dee from ids)::text
            and event = 'session_revoked'), true, 'on the private topic');

select * from finish();
rollback;
