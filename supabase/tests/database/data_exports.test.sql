-- Automatic data exports (20260930000301): what an export holds (and never holds), one build at a time, the
-- parts recorded as soon as they are stored, a request closed without an email, the files expiring after 7 days
-- and the sweep of parts nobody refers to.
begin;
create extension if not exists pgtap with schema extensions;
select plan(43);

create function pg_temp.person(p_email text, p_name text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id)
  values (v_id, p_email, 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  update public.profiles set name = p_name, onboarded_at = now(), birthdate = '1990-01-01', drinks = 'socially'
    where id = v_id;
  return v_id;
end $$;

-- The error code a statement fails with (in the hint), or null when it succeeds.
create function pg_temp.hint(p_sql text) returns text language plpgsql as $$
declare
  v_hint text;
begin
  execute p_sql;
  return null;
exception when others then
  get stacked diagnostics v_hint = pg_exception_hint;
  return v_hint;
end $$;

create temp table ids as select pg_temp.person('ana@export.test', 'Ana') as ana, pg_temp.person('bo-secret@export.test', 'Bo') as bo,
  pg_temp.person('cy@export.test', 'Cy') as cy;

insert into public.profile_sports (user_id, sport_id, per_week, position) select ana, 'running', 3, 0 from ids;
insert into public.swipes (swiper, target, action, note) select ana, bo, 'superlike', 'Sunday run?' from ids;
insert into public.swipes (swiper, target, action) select bo, ana, 'like' from ids;
insert into public.matches (user_a, user_b) select least(ana, bo), greatest(ana, bo) from ids;
insert into public.blocks (blocker, blocked) select ana, cy from ids;
insert into public.reports (reporter, reported, reason, details) select ana, cy, 'spam', 'ads' from ids;
insert into public.reports (reporter, reported, reason, details) select cy, ana, 'fake', 'about ana' from ids;
insert into private.devices (user_id, install_id, model, ip) select ana, gen_random_uuid(), 'iPhone', '203.0.113.9' from ids;
insert into private.support_requests (reference, user_id, email, topic, message)
  select 'DR-EXP001', ana, 'ana@export.test', 'Help', 'A question' from ids;
insert into private.support_messages (request_id, author, body, sent_at)
  select id, 'sup@drafft.test', 'An answer', now() from private.support_requests where reference = 'DR-EXP001';
insert into private.device_checks (user_id, token, environment) select ana, repeat('t', 32), 'production' from ids;
insert into private.sms_sends (user_id, phone, ip) select ana, '+33611112222', '198.51.100.7' from ids;
insert into private.purchase_credits (transaction_id, user_id, product_id, kind, quantity, source, credited_at)
  select 'tx-ana', ana, 'so.drafft.app.boost.5', 'boost', 5, 'webhook', now() from ids;
insert into public.media_flags (user_id, context, key, verdict, reviewed_by)
  select ana, 'profile', 'u/' || ana || '/photos/a.jpg', 'review', 'mod@drafft.test' from ids;
insert into private.consent_events (user_id, terms_version, sensitive_consent) select ana, '2026-09-29', true from ids;
insert into private.staff_notes (user_id, author, body) select ana, 'mod@drafft.test', 'team note about ana' from ids;

-- Bo's own data, distinctive: none of it may reach Ana's export.
update public.profiles set bio = 'bo-private-bio' where id = (select bo from ids);
insert into private.ips (user_id, ip) select bo, '192.0.2.77' from ids;
insert into private.support_requests (reference, user_id, email, topic, message)
  select 'DR-BO0001', bo, 'bo-secret@export.test', 'Help', 'bo-private-message' from ids;

create temp table x as select public.export_data((select ana from ids)) as data;

-- MARK: What an export holds

select is((select data -> 'account' ->> 'email' from x), 'ana@export.test', 'the account, with its email');
select is((select data -> 'profile' ->> 'drinks' from x), 'socially', 'the profile row, lifestyle included');
select is((select data -> 'sports' -> 0 ->> 'sport' from x), 'running', 'sports');
select is((select data -> 'swipes' -> 0 from x) - 'createdAt' - 'opener',
  (select jsonb_build_object('to', jsonb_build_object('id', bo, 'name', 'Bo'), 'action', 'superlike', 'note', 'Sunday run?') from ids),
  'likes sent, the other person by first name');
select is((select jsonb_array_length(data -> 'swipes') from x), 1, 'not the likes received');
select is((select data -> 'matches' -> 0 -> 'with' ->> 'name' from x), 'Bo', 'matches');
select is((select data -> 'blocks' -> 0 -> 'who' ->> 'name' from x), 'Cy', 'blocks');
select is((select data -> 'reportsMade' -> 0 ->> 'details' from x), 'ads', 'reports made');
select ok((select data::text not like '%about ana%' from x), 'never the reports about them (who made them is protected)');
select is((select data -> 'devices' -> 0 ->> 'ip' from x), '203.0.113.9', 'devices and IPs');
select is((select data -> 'support' -> 0 -> 'replies' -> 0 ->> 'body' from x), 'An answer', 'help requests and replies');
select ok((select data::text not like '%sup@drafft.test%' and data::text not like '%mod@drafft.test%' from x),
  'not the staff members'' addresses');
select is((select data -> 'deviceCheck' ->> 'environment' from x), 'production', 'the DeviceCheck record');
select is((select data -> 'verificationTexts' -> 0 ->> 'ip' from x), '198.51.100.7', 'verification texts');
select is((select data -> 'credits' -> 0 ->> 'quantity' from x), '5', 'credits');
select is((select data -> 'mediaChecks' -> 0 ->> 'verdict' from x), 'review', 'the checks of their own photos');
select is((select data -> 'consents' -> 0 ->> 'termsVersion' from x), '2026-09-29', 'the consent log');
select ok((select data::text not like '%team note%' from x), 'never the team''s notes');
select ok((select data::text !~ 'bo-private|bo-secret|192\.0\.2\.77|DR-BO0001' from x), 'nothing of anyone else''s');
select is(public.export_data(gen_random_uuid()), null, 'an account gone: nothing');

-- Every table that names an account is either in the export or left out on purpose: a new one must choose.
select is((select array_agg(t order by t) from (
    select c.table_schema || '.' || c.table_name as t
    from information_schema.columns c join information_schema.tables b using (table_schema, table_name)
    where c.table_schema in ('public', 'private') and c.column_name = 'user_id' and b.table_type = 'BASE TABLE') s),
  (select array_agg(x order by x) from unnest(array[
    -- Exported.
    'private.consent_events', 'private.data_requests', 'private.device_checks', 'private.devices', 'private.ips',
    'private.locations', 'private.moderation_decisions', 'private.moderation_log', 'private.purchase_credits', 'private.selfie_checks',
    'private.sms_sends', 'private.support_requests', 'public.media_flags', 'public.profile_media',
    'public.profile_prompts', 'public.profile_sports', 'public.purchase_events', 'public.push_tokens',
    'public.wallets',
    -- Left out: copies of the profile or of a setting, the team's and safety records, rate limits.
    'private.account_deletions', 'private.account_links', 'private.admin_audit', 'private.banned_accounts',
    'private.deleted_identities', 'private.identity_marks', 'private.moderation_holds', 'private.purchase_sync_calls',
    'private.session_reminders', 'private.staff_deletions', 'private.staff_notes', 'public.profile_cards'
  ]::text[]) x),
  'every table naming an account is exported or left out on purpose');

-- MARK: One build at a time

insert into private.data_requests (user_id) select ana from ids;
create temp table r as select id from private.data_requests where user_id = (select ana from ids);
select is(public.export_begin((select id from r)), 'go', 'the first delivery claims it');
select is(public.export_begin((select id from r)), 'busy', 'another one meanwhile waits');
update private.data_requests set started_at = now() - interval '16 minutes' where id = (select id from r);
select is(public.export_begin((select id from r)), 'go', 'a build that stopped is taken back after 15 minutes');
select is(public.export_begin(-1), 'gone', 'a request gone: gone');

-- MARK: Stored, then fulfilled

select ok(not public.export_ready((select id from r)), 'nothing stored: nothing to fulfil');
select is(pg_temp.hint(format('select public.export_stored(%s, array[%L])', (select id from r), (select bo from ids) || '/1-1.zip')),
  'invalid_paths', 'only the request''s own paths');
select ok(public.export_stored((select id from r), array[(select ana from ids) || '/' || (select id from r) || '-1.zip',
  (select ana from ids) || '/' || (select id from r) || '-2.zip']), 'stored: recorded at once');
select ok((select expires_at = now() + interval '7 days' and fulfilled_at is null from private.data_requests
  where id = (select id from r)), 'the parts expire in 7 days, emailed or not');
select ok(not public.export_stored(-1, array['x']), 'a request gone meanwhile: false, the parts are deleted by db-events');
select ok(public.export_ready((select id from r)), 'emailed: fulfilled');
select is(public.export_begin((select id from r)), 'done', 'fulfilled: done');
select is((select fulfilled_by from private.data_requests where id = (select id from r)), 'automatic', 'automatically');

-- MARK: Closed without an email

insert into private.data_requests (user_id) select cy from ids;
select public.export_closed((select id from private.data_requests where user_id = (select cy from ids)), 'no_email');
select is((select closed_reason || ' ' || (fulfilled_at is not null) from private.data_requests where user_id = (select cy from ids)),
  'no_email true', 'no email: closed, and why');
select set_config('request.jwt.claims', json_build_object('sub', (select cy from ids), 'role', 'authenticated')::text, true);
select public.request_data_export();
select is((select count(*) from private.data_requests where user_id = (select cy from ids)), 2::bigint,
  'a closed request doesn''t stop a new one');

-- MARK: Expiring

update private.data_requests set expires_at = now() - interval '1 minute' where id = (select id from r);
select is(private.queue_export_expiries() + private.queue_export_expiries(), 1, 'an expired file is queued once');
select is(cardinality(public.export_files((select id from r))), 2, 'every part of it is deleted');
select public.export_file_deleted((select id from r));
select is(public.export_files((select id from r)), null, 'deleted: nothing left to delete');

-- MARK: Lifecycle

select throws_ok(format('update private.data_requests set expires_at = null where id = %s', (select id from r)), '23514',
  null, 'files never without their expiry');
select throws_ok(format('update private.data_requests set file_paths = null, expires_at = null where id = %s', (select id from r)),
  '23514', null, 'nor a deletion without files');

-- MARK: Sweep

insert into storage.objects (bucket_id, name, created_at) values
  ('data-exports', (select ana from ids) || '/999-1.zip', now() - interval '2 days'),
  ('data-exports', (select ana from ids) || '/999-2.zip', now() - interval '1 hour'),
  ('data-exports', (select ana from ids) || '/' || (select id from r) || '-1.zip', now() - interval '2 days');
update private.data_requests set file_deleted_at = null where id = (select id from r);
select is(private.queue_export_sweep(), 1, 'a part no request refers to, a day old, is swept; a fresh one waits');
select is((select payload -> 'paths' from private.outbox where event = 'export.sweep'),
  jsonb_build_array((select ana from ids) || '/999-1.zip'), 'by its path');

select ok(not has_function_privilege('authenticated', 'public.export_data(uuid)', 'execute')
  and has_function_privilege('service_role', 'public.export_stored(bigint, text[])', 'execute')
  and exists (select 1 from storage.buckets where id = 'data-exports' and not public)
  and exists (select 1 from cron.job where jobname = 'data-exports-expire')
  and exists (select 1 from cron.job where jobname = 'data-exports-sweep')
  and (select bool_and(erasure) from private.outbox_policies where event in ('export.expired', 'export.sweep')),
  'server side only: a private bucket, the jobs, deletions never dropped when failed');

select * from finish();
rollback;
