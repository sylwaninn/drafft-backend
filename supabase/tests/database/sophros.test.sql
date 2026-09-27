-- sophros, the team's dashboard: roles checked in the database, every action in an append-only audit log,
-- holds with their actor, reports and flags closed, and the app's device reports.
begin;
create extension if not exists pgtap with schema extensions;
select plan(34);

create function pg_temp.person(p_email text, p_name text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id)
  values (v_id, p_email, 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  update public.profiles set name = p_name where id = v_id;
  return v_id;
end $$;

create function pg_temp.login(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

grant execute on all functions in schema pg_temp to authenticated;
create temp table ids as select pg_temp.person('ana@sophros.test', 'Ana') as ana,
  pg_temp.person('bo@sophros.test', 'Bozzwick') as bo, pg_temp.person('cy@sophros.test', 'Cy') as cy;
grant select on ids to authenticated;

insert into private.staff (email, role) values
  ('sup@drafft.test', 'support'), ('mod@drafft.test', 'moderator'), ('boss@drafft.test', 'admin');
insert into private.staff (email, role, disabled_at) values ('gone@drafft.test', 'admin', now());

-- MARK: Staff

select is(public.admin_whoami('MOD@drafft.test '), 'moderator', 'a role, whatever the case');
select is(public.admin_whoami('gone@drafft.test'), null, 'disabled staff is nobody');
select is(public.admin_whoami('someone@else.dev'), null, 'strangers are nobody');
select throws_ok($$select public.admin_overview('someone@else.dev')$$, 'P0001', 'not allowed', 'strangers read nothing');
select lives_ok($$select public.admin_overview('sup@drafft.test')$$, 'support reads the overview');
select throws_ok($$select public.admin_staff_list('mod@drafft.test')$$, 'P0001', 'not allowed', 'only admins see the staff');
select throws_ok($$select public.admin_set_staff('boss@drafft.test', 'boss@drafft.test', 'support')$$,
  'P0001', 'you can''t change your own role', 'nobody demotes themselves');
select public.admin_set_staff('boss@drafft.test', 'New@Drafft.test', 'support');
select is((select role from private.staff where email = 'new@drafft.test'), 'support', 'staff added, lowercased');
select ok(not has_function_privilege('authenticated', 'public.admin_user(text, uuid)', 'execute')
    and not has_function_privilege('anon', 'public.admin_set_hold(text, uuid, public.moderation_state, text)', 'execute')
    and has_function_privilege('service_role', 'public.admin_set_hold(text, uuid, public.moderation_state, text)', 'execute'),
  'the dashboard functions are for the service role only');

-- MARK: Accounts

select is(jsonb_array_length(public.admin_users('sup@drafft.test', 'ANA@sophros')), 1, 'search by email');
select is(public.admin_users('sup@drafft.test', 'ozzwi') -> 0 ->> 'name', 'Bozzwick', 'search by name');
select is(jsonb_array_length(public.admin_users('sup@drafft.test', '%')), 0, 'wildcards are literal');
select is(public.admin_user('sup@drafft.test', (select ana from ids)) -> 'auth' ->> 'email', 'ana@sophros.test', 'the whole account');
select is((select action from private.admin_audit order by id desc limit 1), 'user.view', 'opening an account is logged');
select throws_ok(format($$select public.admin_user('sup@drafft.test', %L)$$, gen_random_uuid()), 'P0001', 'no such account',
  'an unknown account');

-- MARK: Holds

select throws_ok(format($$select public.admin_set_hold('sup@drafft.test', %L, 'review', 'check')$$, (select bo from ids)),
  'P0001', 'not allowed', 'support can''t hold an account');
select throws_ok(format($$select public.admin_set_hold('mod@drafft.test', %L, 'review', ' ')$$, (select bo from ids)),
  'P0001', 'say why', 'a hold needs a reason');
select public.admin_set_hold('mod@drafft.test', (select bo from ids), 'banned', 'scam links');
select is((select moderation::text from public.profiles where id = (select bo from ids)), 'banned', 'banned');
select is((select actor || ': ' || note from private.moderation_log where user_id = (select bo from ids) order by id desc limit 1),
  'mod@drafft.test: scam links', 'the log says who and why');
select throws_ok(format($$select public.admin_set_hold('mod@drafft.test', %L, null, 'appeal')$$, (select bo from ids)),
  'P0001', 'not allowed', 'lifting a ban takes an admin');
select lives_ok(format($$select public.admin_set_hold('boss@drafft.test', %L, null, 'appeal accepted')$$, (select bo from ids)),
  'an admin lifts it');
select throws_ok($$update private.admin_audit set reason = 'nothing' where true$$, 'P0001', 'the audit log is append-only',
  'the trail can''t be rewritten');

-- MARK: Reports, flags, conversations

set local role authenticated;
select pg_temp.login((select ana from ids));
select public.report_user((select cy from ids), 'harassment', 'insults');
reset role;
select is((select count(*) from jsonb_array_elements(public.admin_reports('sup@drafft.test')) r
    where r -> 'reported' ->> 'id' = (select cy::text from ids)), 1::bigint, 'the report is open');
select public.admin_resolve_report('mod@drafft.test', (select id from public.reports where reported = (select cy from ids)), 'warned');
select is((select handled_by || ': ' || resolution from public.reports where reported = (select cy from ids)), 'mod@drafft.test: warned',
  'and closed, by whom and how');

insert into public.media_flags (user_id, context, key, verdict, labels)
  values ((select cy from ids), 'chat', 'u/x/chat/1.jpg', 'rejected', '{Nudity}');
select public.admin_resolve_flags('mod@drafft.test', array[(select max(id) from public.media_flags)], 'fine');
select is((select count(*) from jsonb_array_elements(public.admin_flags('mod@drafft.test')) f
    where f -> 'person' ->> 'id' = (select cy::text from ids)), 0::bigint, 'a flag looked at leaves the queue');
select throws_ok($$select public.admin_log('mod@drafft.test', 'conversation.view', null, 'm', '')$$,
  'P0001', 'say why', 'reading a conversation needs a reason');
select throws_ok($$select public.admin_matches('sup@drafft.test')$$, 'P0001', 'not allowed', 'support reads no conversation');

-- MARK: Support replies

create temp table req as select public.create_support_request((select ana from ids), 'ana@sophros.test', 'fr', 'Help', 'Stuck') as ref;
select throws_ok(format($$select public.admin_reply_support('sup@drafft.test', %s, '  ')$$,
    (select id from private.support_requests where reference = (select ref from req))),
  'P0001', 'write the reply first', 'a reply needs words');
select public.admin_reply_support('sup@drafft.test', (select id from private.support_requests where reference = (select ref from req)), 'Bonjour Ana');
select is((select handled_by from private.support_requests where reference = (select ref from req)), 'sup@drafft.test',
  'replying closes the request');
select is((select count(*) from private.outbox o join private.support_messages m on (o.payload ->> 'id')::bigint = m.id
    where o.event = 'support.reply' and m.body = 'Bonjour Ana'), 1::bigint, 'db-events is asked to email it');
select is(public.admin_support('sup@drafft.test', false, (select ref from req)) -> 0 -> 'replies' -> 0 ->> 'body', 'Bonjour Ana',
  'the thread shows it');

-- MARK: Conversation filters

insert into public.matches (user_a, user_b) select least(ana, cy), greatest(ana, cy) from ids;
select is(jsonb_array_length(public.admin_matches('mod@drafft.test', null, 'cy@sophros', 'all', true)), 1,
  'by email, with a report between them');

-- MARK: Device reports

select set_config('request.headers', '{"x-forwarded-for": "203.0.113.7, 10.0.0.1", "cf-ipcountry": "fr"}', true);
set local role authenticated;
select pg_temp.login((select ana from ids));
select public.report_app_open('6f1c1c1e-0000-4000-8000-000000000001', '{"model": "iPhone17,1", "os": "26.0", "app": "1.0"}');
select public.report_app_open('6f1c1c1e-0000-4000-8000-000000000001', '{"model": "iPhone17,1", "os": "26.0", "app": "1.0"}');
select pg_temp.login((select cy from ids));
select public.report_app_open('6f1c1c1e-0000-4000-8000-000000000001', '{"model": "iPhone17,1"}');
reset role;
select is((select host(ip) || ' ' || country || ' ' || opens from private.devices where user_id = (select ana from ids)),
  '203.0.113.7 FR 1', 'the device, its IP and country; a second open within a minute writes nothing');
select is((select count(*) from jsonb_array_elements(public.admin_related('sup@drafft.test', (select ana from ids))) r
    where r -> 'person' ->> 'id' = (select cy::text from ids)), 2::bigint, 'same install and same IP: related');

select * from finish();
rollback;
