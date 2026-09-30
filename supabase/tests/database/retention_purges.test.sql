-- Retention on the privacy policy's schedule (20260930000101): private.purge_expired() deletes what is past its
-- period and keeps what isn't, the audit log accepts no other deletion, deletion records hold no identity in
-- clear, dead letters go 30 days after they failed (erasures never), and a job that stops running is flagged.
begin;
create extension if not exists pgtap with schema extensions;
select plan(67);

create function pg_temp.person(p_email text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id)
  values (v_id, p_email, 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  update public.profiles set onboarded_at = now(), birthdate = '1990-01-01' where id = v_id;
  return v_id;
end $$;

-- The error code a statement fails with (private.fail and the guards put it in the hint, a check its
-- SQLSTATE), or null when it succeeds.
create function pg_temp.fails(p_sql text) returns text language plpgsql as $$
declare
  v_hint text;
  v_state text;
begin
  execute p_sql;
  return null;
exception when others then
  get stacked diagnostics v_hint = pg_exception_hint, v_state = returned_sqlstate;
  return coalesce(nullif(v_hint, ''), v_state);
end $$;

-- ana and bo: ordinary accounts; ed: banned; hal: on hold for over a year; gone: a banned account erased 2
-- years ago; old: a banned account erased 4 years ago.
create temp table ids as select pg_temp.person('ana@purge.test') as ana, pg_temp.person('bo@purge.test') as bo,
  pg_temp.person('ed@purge.test') as ed, pg_temp.person('hal@purge.test') as hal, gen_random_uuid() as gone,
  gen_random_uuid() as old;
update public.profiles set moderation = 'banned' where id = (select ed from ids);
update public.profiles set moderation = 'review' where id = (select hal from ids);
update private.moderation_log set created_at = now() - interval '2 years' where user_id = (select hal from ids);
insert into private.moderation_log (user_id, state, note, created_at)
  select hal, 'review', 'an earlier hold', now() - interval '3 years' from ids;
insert into private.identity_marks (kind, hash, state, user_id)
  select 'email', repeat('a', 64), 'banned', gone from ids;
insert into private.banned_accounts (user_id, banned_at, erased_at)
  select gone, now() - interval '5 years', now() - interval '2 years' from ids
  union all select old, now() - interval '6 years', now() - interval '4 years' from ids;

-- MARK: Periods and who counts as banned

select is(private.retention_period('moderation', true), interval '3 years', 'one place for the periods');
select is(pg_temp.fails($$select private.retention_period('nope')$$), 'P0001', 'an unknown period is an error, not null');
select ok(private.banned_account((select ed from ids)), 'an account banned now is banned');
select ok(private.banned_account((select gone from ids)), 'so is an erased account, for 3 years after its erasure');
select ok(not private.banned_account((select ana from ids)) and not private.banned_account(null), 'anyone else is not');

create temp table lifted as select pg_temp.person('lif@purge.test') as lif;
update public.profiles set moderation = 'banned' where id = (select lif from lifted);
update public.profiles set moderation = null where id = (select lif from lifted);
select ok(not private.banned_account((select lif from lifted)), 'a ban lifted on appeal no longer counts');

-- MARK: Rows old and recent

insert into public.reports (reporter, reported, reason, details, created_at, handled_at)
  select ana, bo, 'spam'::public.report_reason, 'handled long ago', now() - interval '3 years', now() - interval '13 months' from ids
  union all select ana, bo, 'spam', 'handled recently', now() - interval '2 years', now() - interval '11 months' from ids
  union all select bo, ana, 'spam', 'still open', now() - interval '5 years', null from ids;

insert into private.moderation_log (user_id, state, note, created_at)
  select ana, null::public.moderation_state, 'old', now() - interval '13 months' from ids
  union all select ana, null, 'recent', now() - interval '11 months' from ids
  union all select ed, 'review'::public.moderation_state, 'banned, 2 years', now() - interval '2 years' from ids
  union all select ed, 'review', 'banned, 4 years', now() - interval '4 years' from ids;

insert into private.staff_notes (user_id, author, body, created_at)
  select ana, 'mod@drafft.test', 'old', now() - interval '13 months' from ids
  union all select ana, 'mod@drafft.test', 'recent', now() - interval '11 months' from ids
  union all select ed, 'mod@drafft.test', 'banned, 2 years', now() - interval '2 years' from ids
  union all select ed, 'mod@drafft.test', 'banned, 4 years', now() - interval '4 years' from ids;

insert into public.media_flags (user_id, context, key, verdict, created_at, reviewed_at)
  select ana, 'chat', 'u/' || ana || '/chat/old.jpg', 'review', now() - interval '2 years', now() - interval '13 months' from ids
  union all select ana, 'chat', 'u/' || ana || '/chat/reviewed.jpg', 'review', now() - interval '2 years', now() - interval '6 months' from ids
  union all select ana, 'chat', 'u/' || ana || '/chat/never.jpg', 'review', now() - interval '13 months', null from ids
  union all select ed, 'chat', 'u/' || ed || '/chat/banned.jpg', 'rejected', now() - interval '2 years', null from ids
  union all select ed, 'chat', 'u/' || ed || '/chat/banned-old.jpg', 'rejected', now() - interval '4 years', null from ids;

insert into private.account_links (user_id, deleted_user_id, via, created_at)
  select ana, bo, 'email', now() - interval '13 months' from ids
  union all select bo, ana, 'phone', now() - interval '11 months' from ids
  union all select ana, ed, 'phone', now() - interval '2 years' from ids
  union all select ed, bo, 'oauth', now() - interval '2 years' from ids
  union all select ana, ed, 'oauth', now() - interval '4 years' from ids;

insert into private.admin_audit (actor, action, user_id, created_at)
  select 'mod@drafft.test', 'user.view', ana, now() - interval '13 months' from ids
  union all select 'mod@drafft.test', 'user.view', ana, now() - interval '11 months' from ids
  union all select 'mod@drafft.test', 'user.search', null, now() - interval '13 months' from ids
  union all select 'mod@drafft.test', 'hold.set', ed, now() - interval '2 years' from ids
  union all select 'mod@drafft.test', 'hold.set', gone, now() - interval '2 years' from ids
  union all select 'mod@drafft.test', 'hold.set', old, now() - interval '2 years' from ids;

insert into private.support_requests (reference, user_id, email, topic, message, created_at)
  select 'DR-OLD001', ana, 'ana@purge.test', 'Help', 'old', now() - interval '4 years' from ids
  union all select 'DR-OLD002', ana, 'ana@purge.test', 'Help', 'old, answered later', now() - interval '4 years' from ids
  union all select 'DR-OLD003', null, 'x@purge.test', 'Help', 'old, never answered', now() - interval '4 years' from ids
  union all select 'DR-NEW001', null, 'someone@purge.test', 'Help', 'recent', now() - interval '2 years' from ids;
insert into private.support_messages (request_id, author, body, created_at)
  select id, 'sup@drafft.test', 'reply', now() - interval '4 years' from private.support_requests where reference = 'DR-OLD001'
  union all select id, 'sup@drafft.test', 'reply', now() - interval '1 year' from private.support_requests where reference = 'DR-OLD002';

insert into public.purchase_events (id, type, user_id, event_at, effect)
  select 'evt-old', 'NON_RENEWING_PURCHASE', ana, now() - interval '11 years', '+5 boost' from ids
  union all select 'evt-new', 'NON_RENEWING_PURCHASE', ana, now() - interval '9 years', '+5 boost' from ids;
insert into private.purchase_credits (transaction_id, user_id, product_id, kind, quantity, source, credited_at, refunded_at, created_at)
  select 'tx-old', ana, 'so.drafft.app.boost.5', 'boost', 5, 'webhook', now() - interval '11 years', null, now() - interval '11 years' from ids
  union all select 'tx-refunded', ana, 'so.drafft.app.boost.5', 'boost', 5, 'webhook', now() - interval '11 years',
    now() - interval '9 years', now() - interval '11 years' from ids;

-- MARK: Identity marks follow their account

insert into auth.identities (provider_id, user_id, identity_data, provider)
  select 'apple-bo', bo, '{}'::jsonb, 'apple' from ids;
insert into public.reports (reporter, reported, reason) select ana, bo, 'harassment' from ids;
update public.profiles set moderation = 'review' where id = (select bo from ids);
select ok((select bool_and(deleted_at is null) from private.identity_marks where user_id = (select bo from ids)),
  'the marks of a live account have no deletion date');
select is(public.retain_deleted_account((select bo from ids)) ->> 'basis', 'hold', 'bo deletes his account: kept');
select ok((select bool_and(m.deleted_at = p.deleted_at) from private.identity_marks m join public.profiles p on p.id = m.user_id
    where m.user_id = (select bo from ids)), 'his marks take the deletion date');
select ok((select deleted_at is not null from private.identity_marks where user_id = (select gone from ids)),
  'a mark whose account is already gone has one too');

create temp table erased as select pg_temp.person('ivy@purge.test') as ivy, pg_temp.person('kay@purge.test') as kay;
update public.profiles set moderation = 'review' where id = (select ivy from erased);
update public.profiles set moderation = 'banned' where id = (select ivy from erased);
delete from auth.users where id = (select ivy from erased);
select ok((select bool_and(deleted_at is not null) and count(*) > 0 from private.identity_marks where user_id = (select ivy from erased)),
  'an erased account''s marks get the date of the erasure');
select isnt((select erased_at from private.banned_accounts where user_id = (select ivy from erased)), null::timestamptz,
  'and its ban the date of the erasure');

-- A kept account erased later keeps its first date.
update public.profiles set moderation = 'review' where id = (select kay from erased);
select public.retain_deleted_account(kay) from erased;
update private.identity_marks set deleted_at = now() - interval '2 years' where user_id = (select kay from erased);
delete from auth.users where id = (select kay from erased);
select ok((select bool_and(deleted_at < now() - interval '23 months') from private.identity_marks
    where user_id = (select kay from erased)), 'a kept account erased later keeps its deletion date');

-- Marks taken over by a new account (inherit_hold) belong to a live account again.
insert into private.identity_marks (kind, hash, state, user_id) values ('oauth', repeat('e', 64), 'selfie', gen_random_uuid());
update private.identity_marks set deleted_at = now() - interval '4 years' where hash = repeat('e', 64);
update private.identity_marks set user_id = (select ana from ids) where hash = repeat('e', 64);
select is((select deleted_at from private.identity_marks where hash = repeat('e', 64)), null::timestamptz,
  'a mark taken over by a live account loses its deletion date');

-- MARK: The deletion record keeps no identity in clear

select is((select identities - 'oauth' from private.account_deletions where user_id = (select bo from ids)),
  '{"email": true, "phone": false}'::jsonb, 'the record says which identities there were');
select ok((select identities::text not like '%purge.test%' and identities::text not like '%apple-bo%'
    from private.account_deletions where user_id = (select bo from ids)), 'but never their values');
select is((select identities -> 'oauth' -> 0 ->> 'provider' from private.account_deletions where user_id = (select bo from ids)),
  'apple', 'the sign-in''s provider stays');
select is(private.identities_summary('{"email": "x@y.z", "phone": "33612345678", "oauth": [{"provider": "google",
    "providerId": "g-1", "email": "x@gmail.com", "createdAt": "2026-01-01"}]}'),
  '{"email": true, "phone": true, "oauth": [{"provider": "google", "createdAt": "2026-01-01", "lastSignInAt": null}]}'::jsonb,
  'existing records are converted the same way');
select is(private.identities_summary('{"email": true, "phone": false, "oauth": []}'),
  '{"email": true, "phone": false, "oauth": []}'::jsonb, 'a summary summarised again stays the same');
select is(pg_temp.fails(format($$update private.account_deletions set identities = '{"email": "bo@purge.test"}'
    where user_id = %L$$, (select bo from ids))), '23514', 'a value in clear can''t be stored');
insert into private.staff (email, role) values ('sup@drafft.test', 'support');
select ok(public.admin_users('sup@drafft.test', 'BO@purge.test') @> jsonb_build_array(jsonb_build_object('id', (select bo from ids))),
  'sophros finds the kept account by its old email, through the digest');
select is(jsonb_array_length(public.admin_users('sup@drafft.test', 'purge.test', 'deleted')), 0,
  'but not by a part of it');

-- Deletion records past their period: jo (a report), kim (banned), hed (on hold), all deleted years ago.
create temp table kept as select pg_temp.person('jo@purge.test') as jo, pg_temp.person('kim@purge.test') as kim,
  pg_temp.person('hed@purge.test') as hed;
insert into public.reports (reporter, reported, reason) select ana, jo, 'harassment' from ids, kept;
update public.profiles set moderation = 'banned' where id = (select kim from kept);
update public.profiles set moderation = 'selfie' where id = (select hed from kept);
select public.retain_deleted_account(jo), public.retain_deleted_account(kim), public.retain_deleted_account(hed) from kept;
update private.account_deletions set deleted_at = now() - interval '2 years' where user_id in (select jo from kept union select hed from kept);
update private.account_deletions set deleted_at = now() - interval '4 years' where user_id = (select kim from kept);
update private.identity_marks set deleted_at = now() - interval '4 years'
  where user_id in (select kim from kept union select hed from kept);

-- MARK: Purge

-- Marks: deleted 2 years ago (a hold's: gone; a ban's: kept), deleted 4 years ago (a ban's: gone).
insert into private.identity_marks (kind, hash, state, user_id) values
  ('phone', repeat('b', 64), 'review', gen_random_uuid()),
  ('phone', repeat('c', 64), 'banned', gen_random_uuid()),
  ('phone', repeat('d', 64), 'banned', gen_random_uuid());
update private.identity_marks set deleted_at = now() - interval '2 years' where hash in (repeat('b', 64), repeat('c', 64));
update private.identity_marks set deleted_at = now() - interval '4 years' where hash = repeat('d', 64);

create temp table purged as select private.purge_expired() as counts;

select is((select array_agg(details order by details) from public.reports where reason = 'spam'),
  array['handled recently', 'still open'], 'reports: handled over a year ago go, open ones never');
select is((select array_agg(note order by note) from private.moderation_log where user_id = (select ana from ids)),
  array['recent'], 'moderation log: over a year goes');
select is((select array_agg(note order by note) from private.moderation_log where user_id = (select ed from ids) and note like 'banned%'),
  array['banned, 2 years'], 'about a banned account: 3 years');
select is((select array_agg(coalesce(note, 'the hold') order by created_at) from private.moderation_log where user_id = (select hal from ids)),
  array['the hold'], 'the entry behind a hold still in force stays, however old; earlier ones go');
select is((select array_agg(body order by body) from private.staff_notes),
  array['banned, 2 years', 'recent'], 'staff notes: 1 year, 3 about a banned account');
select is((select array_agg(split_part(key, '/', 4) order by split_part(key, '/', 4)) from public.media_flags),
  array['banned.jpg', 'reviewed.jpg'], 'flags: 1 year after their review (or since raised), 3 about a banned account');
select is((select array_agg(via || ' ' || created_at::date order by via, created_at) from private.account_links),
  array['oauth ' || (now() - interval '2 years')::date, 'phone ' || (now() - interval '2 years')::date,
    'phone ' || (now() - interval '11 months')::date],
  'account links: 1 year, 3 when either side is banned');
select is((select array_agg(action || ' ' || coalesce(user_id::text, '-') order by action, user_id::text) from private.admin_audit
    where created_at < now() - interval '1 day'),
  (select array_agg(x order by x) from ids, unnest(array['hold.set ' || ed, 'hold.set ' || gone, 'user.view ' || ana]) x),
  'audit log: 1 year, 3 about a banned account, erased or not; the ban of one erased 4 years ago is forgotten');
select is((select array_agg(hash order by hash) from private.identity_marks where hash in (repeat('b', 64), repeat('c', 64), repeat('d', 64))),
  array[repeat('c', 64)], 'identity marks: 1 year after the deletion, 3 for a ban');
select ok(exists (select 1 from private.identity_marks where user_id = (select ed from ids)),
  'the marks of an account that still exists stay');
select ok(exists (select 1 from private.identity_marks where hash = repeat('e', 64)), 'so do marks taken over');
select ok(not exists (select 1 from private.identity_marks where user_id = (select kay from erased)),
  'those of a kept account erased since go on its first date');
select ok((select count(*) > 0 from private.identity_marks where user_id = (select hed from kept))
    and (select count(*) > 0 from private.identity_marks where user_id = (select kim from kept)),
  'a kept account still on hold or banned keeps its marks, however old its deletion');
select is((select count(*) from private.deleted_identities where user_id = (select jo from kept)), 0::bigint,
  'digests of a kept account: gone a year after the deletion');
select is((select identities || jsonb_build_object('purged', identities_purged_at is not null)
    from private.account_deletions where user_id = (select jo from kept)), '{"purged": true}'::jsonb,
  'and what the record says of them, marked as purged');
select ok((select count(*) > 0 from private.deleted_identities where user_id = (select kim from kept))
    and (select count(*) > 0 from private.deleted_identities where user_id = (select hed from kept)),
  'not while the kept account is banned or on hold');
select ok(exists (select 1 from private.account_deletions where user_id = (select jo from kept)),
  'the record itself stays with the kept account');
select is((select array_agg(user_id) from private.banned_accounts where user_id in (select gone from ids union select old from ids)),
  (select array[gone] from ids), 'a ban is remembered 3 years after the account''s erasure');
select is((select array_agg(reference order by reference) from private.support_requests),
  array['DR-NEW001', 'DR-OLD002'], 'support: 3 years after the last exchange, answered or not');
select is((select count(*) from private.support_messages), 1::bigint, 'with their messages');
select is((select array_agg(id order by id) from public.purchase_events), array['evt-new'], 'purchase events: 10 years');
select is((select array_agg(transaction_id) from private.purchase_credits), array['tx-refunded'],
  'purchase credits: 10 years after the last change');
select is((select counts from purged), '{"reports": 1, "moderation_log": 3, "staff_notes": 2, "media_flags": 3,
    "account_links": 2, "admin_audit": 3, "identity_marks": 3, "deleted_identities": 1, "deletion_records_cleared": 1,
    "banned_accounts": 1, "support_requests": 2, "purchase_events": 1, "purchase_credits": 1}'::jsonb,
  'the counts say what went');
select is((select counts from private.job_runs where job = 'privacy-purge' and finished_at is not null),
  (select counts from purged), 'the run is recorded with them');
select ok(exists (select 1 from cron.job where jobname = 'privacy-purge' and command like '%purge_expired%'),
  'it runs every day');

-- MARK: The audit log stays append-only

select is(pg_temp.fails('delete from private.admin_audit'), 'append_only', 'nobody else deletes from it');
insert into private.admin_audit (actor, action, created_at) values ('mod@drafft.test', 'user.search', now() - interval '2 years');
select is(pg_temp.fails($$delete from private.admin_audit where created_at < now() - interval '1 year'$$), 'append_only',
  'not even a row past its period, outside the purge');
select set_config('drafft.purging', 'on', true);
select is(pg_temp.fails($$delete from private.admin_audit where created_at < now() - interval '1 year'$$), 'append_only',
  'the old purge setting opens nothing');
select set_config('drafft.purging', '', true);
select is(pg_temp.fails($$update private.admin_audit set reason = 'edited'$$), 'append_only', 'nor edits anything');
select is(pg_temp.fails('truncate private.admin_audit'), 'append_only', 'nor truncates');
select ok(not has_table_privilege('service_role', 'private.job_runs', 'insert')
  and not has_table_privilege('authenticated', 'private.job_runs', 'insert'), 'nobody else can pose as the purge');

-- MARK: Dead letters

insert into private.outbox (event, payload, failed_at, delivered_at, created_at) values
  ('support.created', '{"id": 1}', now() - interval '31 days', null, now() - interval '32 days'),
  ('support.created', '{"id": 2}', now() - interval '29 days', null, now() - interval '30 days'),
  ('support.created', '{"id": 3}', now() - interval '31 days', now() - interval '2 days', now() - interval '32 days'),
  ('media.deleted', '{"id": 4}', now() - interval '31 days', null, now() - interval '32 days'),
  ('selfie.delete', '{"id": 5}', now() - interval '90 days', null, now() - interval '91 days');
select is(private.outbox_cleanup() -> 'deadLetters', '{"support.created": 1}'::jsonb, 'the cleanup counts what it dropped');
select is((select array_agg(payload ->> 'id' order by payload ->> 'id') from private.outbox where payload ->> 'id' ~ '^\d$'),
  array['2', '3', '4', '5'], 'a dead letter goes 30 days after it failed; a delivered one waits for its own period');
select ok((select bool_and(erasure) from private.outbox_policies where event in ('media.deleted', 'selfie.delete',
  'account.soft_deleted', 'account.moderation', 'stream.user')), 'erasures are marked in their policies');
select ok(exists (select 1 from cron.job where jobname = 'outbox-cleanup' and command like '%outbox_cleanup%'),
  'the cleanup runs every day');

-- MARK: Jobs behind

select is(private.ops_state() -> 'jobsBehind', '[]'::jsonb, 'both jobs ran: nothing behind');
update private.watched_jobs set since = now() - interval '3 days';
delete from private.job_runs;
select is(private.ops_state() -> 'jobsBehind',
  '[{"job": "outbox-cleanup", "lastRunAt": null}, {"job": "privacy-purge", "lastRunAt": null}]'::jsonb,
  'no completed run in 26 hours: behind');
insert into private.job_runs (job, started_at, finished_at, counts) values
  ('privacy-purge', now() - interval '2 hours', now() - interval '2 hours', '{}'),
  ('outbox-cleanup', now() - interval '2 hours', now() - interval '2 hours', '{}');
insert into cron.job_run_details (jobid, runid, status, start_time, end_time, command, return_message)
  select jobid, 999999, 'failed', now() - interval '1 hour', now() - interval '1 hour', command, 'boom'
  from cron.job where jobname = 'privacy-purge';
select is(private.ops_state() -> 'jobsBehind' -> 0 ->> 'job', 'privacy-purge', 'a failed run since the last one: behind');
select is(jsonb_array_length(private.ops_state() -> 'jobsBehind'), 1, 'the other job is fine');
update private.outbox set failed_at = null, discarded_at = now() where failed_at is not null;
update private.ops_incidents set closed_at = now() where closed_at is null;
select private.ops_check();
select ok(exists (select 1 from private.ops_incidents where closed_at is null), 'a job behind opens an incident');

select ok(not has_function_privilege('authenticated', 'private.purge_expired()', 'execute')
  and not has_function_privilege('service_role', 'private.purge_expired()', 'execute')
  and not has_function_privilege('service_role', 'private.outbox_cleanup()', 'execute'), 'only the jobs run them');

-- MARK: Records written before this migration

-- Their clear values, as 20260928000131 wrote them: the check, added after the conversion, is lifted here.
alter table private.account_deletions drop constraint account_deletions_identities_summary;
create temp table legacy as select pg_temp.person('leg@purge.test') as leg;
insert into private.account_deletions (user_id, basis, identities)
  select leg, 'report', '{"email": "Leg@Purge.test", "phone": "33611112222",
    "oauth": [{"provider": "apple", "providerId": "apple-leg", "createdAt": "2026-01-01"}]}' from legacy;
select is(private.convert_deletion_identities(), 1::bigint, 'the conversion changes the records in clear only');
select ok((select identities::text !~ '@|3361|apple-leg' from private.account_deletions where user_id = (select leg from legacy)),
  'no value is left in them');
select is((select array_agg(kind order by kind) from private.deleted_identities where user_id = (select leg from legacy)),
  array['email', 'oauth', 'phone'], 'each identity is digested first');
select ok(exists (select 1 from private.deleted_identities where user_id = (select leg from legacy)
    and hash = private.identity_hash('email', private.normalize_email('leg@purge.test'))),
  'with the same digest a sign-up computes');

select * from finish();
rollback;
