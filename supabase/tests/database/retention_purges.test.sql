-- Retention on the privacy policy's schedule (20260930000101): private.purge_expired() deletes what is past its
-- period and keeps what isn't, the audit log accepts no other deletion, deletion records hold no identity in
-- clear, and dead letters go 30 days after they failed.
begin;
create extension if not exists pgtap with schema extensions;
select plan(41);

create function pg_temp.person(p_email text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id)
  values (v_id, p_email, 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  update public.profiles set onboarded_at = now(), birthdate = '1990-01-01' where id = v_id;
  return v_id;
end $$;

-- ana and bo: ordinary accounts; ed: banned; hal: on hold for over a year; gone: an account erased long ago
-- whose ban marks remain (no profile any more).
create temp table ids as select pg_temp.person('ana@purge.test') as ana, pg_temp.person('bo@purge.test') as bo,
  pg_temp.person('ed@purge.test') as ed, pg_temp.person('hal@purge.test') as hal, gen_random_uuid() as gone;
update public.profiles set moderation = 'banned' where id = (select ed from ids);
update public.profiles set moderation = 'review' where id = (select hal from ids);
update private.moderation_log set created_at = now() - interval '2 years' where user_id = (select hal from ids);
insert into private.identity_marks (kind, hash, state, user_id)
  select 'email', repeat('a', 64), 'banned', gone from ids;

-- MARK: Who counts as banned

select ok(private.banned_account((select ed from ids)), 'an account banned now is banned');
select ok(private.banned_account((select gone from ids)), 'so is an erased account whose ban marks remain');
select ok(not private.banned_account((select ana from ids)) and not private.banned_account(null), 'anyone else is not');

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
  union all select ed, 'mod@drafft.test', 'banned, 2 years', now() - interval '2 years' from ids;

insert into public.media_flags (user_id, context, key, verdict, created_at, reviewed_at)
  select ana, 'chat', 'u/' || ana || '/chat/old.jpg', 'review', now() - interval '2 years', now() - interval '13 months' from ids
  union all select ana, 'chat', 'u/' || ana || '/chat/reviewed.jpg', 'review', now() - interval '2 years', now() - interval '6 months' from ids
  union all select ana, 'chat', 'u/' || ana || '/chat/never.jpg', 'review', now() - interval '13 months', null from ids
  union all select ed, 'chat', 'u/' || ed || '/chat/banned.jpg', 'rejected', now() - interval '2 years', null from ids;

insert into private.account_links (user_id, deleted_user_id, via, created_at)
  select ana, bo, 'email', now() - interval '13 months' from ids
  union all select bo, ana, 'phone', now() - interval '11 months' from ids
  union all select ana, ed, 'phone', now() - interval '2 years' from ids;

insert into private.admin_audit (actor, action, user_id, created_at)
  select 'mod@drafft.test', 'user.view', ana, now() - interval '13 months' from ids
  union all select 'mod@drafft.test', 'user.view', ana, now() - interval '11 months' from ids
  union all select 'mod@drafft.test', 'user.search', null, now() - interval '13 months' from ids
  union all select 'mod@drafft.test', 'hold.set', ed, now() - interval '2 years' from ids
  union all select 'mod@drafft.test', 'hold.set', gone, now() - interval '4 years' from ids;

insert into private.support_requests (reference, user_id, email, topic, message, created_at)
  select 'DR-OLD001', ana, 'ana@purge.test', 'Help', 'old', now() - interval '4 years' from ids
  union all select 'DR-OLD002', ana, 'ana@purge.test', 'Help', 'old, answered later', now() - interval '4 years' from ids
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

create temp table erased as select pg_temp.person('ivy@purge.test') as ivy;
update public.profiles set moderation = 'review' where id = (select ivy from erased);
update public.profiles set moderation = 'banned' where id = (select ivy from erased);
delete from auth.users where id = (select ivy from erased);
select ok((select bool_and(deleted_at is not null) and count(*) > 0 from private.identity_marks where user_id = (select ivy from erased)),
  'an erased account''s marks get the date of the erasure');

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
insert into private.staff (email, role) values ('sup@drafft.test', 'support');
select ok(public.admin_users('sup@drafft.test', 'BO@purge.test') @> jsonb_build_array(jsonb_build_object('id', (select bo from ids))),
  'sophros finds the kept account by its old email, through the digest');
select is(jsonb_array_length(public.admin_users('sup@drafft.test', 'purge.test', 'deleted')), 0,
  'but not by a part of it');

-- Deletion records past their period.
create temp table kept as select pg_temp.person('jo@purge.test') as jo, pg_temp.person('kim@purge.test') as kim;
insert into public.reports (reporter, reported, reason) select ana, jo, 'harassment' from ids, kept;
update public.profiles set moderation = 'banned' where id = (select kim from kept);
select public.retain_deleted_account(jo), public.retain_deleted_account(kim) from kept;
update private.account_deletions set deleted_at = now() - interval '2 years' where user_id in (select jo from kept union select kim from kept);

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
select is((select count(*) from private.moderation_log where user_id = (select hal from ids)), 1::bigint,
  'the entry behind a hold still in force stays, however old');
select is((select array_agg(body order by body) from private.staff_notes),
  array['banned, 2 years', 'recent'], 'staff notes: 1 year, 3 about a banned account');
select is((select array_agg(split_part(key, '/', 4) order by split_part(key, '/', 4)) from public.media_flags),
  array['banned.jpg', 'reviewed.jpg'], 'flags: 1 year after their review (or since raised), 3 about a banned account');
select is((select array_agg(via order by via) from private.account_links),
  array['phone', 'phone'], 'account links: 1 year, 3 when one side is banned');
select is((select array_agg(action || ' ' || coalesce(user_id::text, '-') order by action, id) from private.admin_audit
    where created_at < now() - interval '1 day'),
  (select array['hold.set ' || ed, 'user.view ' || ana] from ids), 'audit log: 1 year, 3 about a banned account, deleted or not');
select is((select array_agg(hash order by hash) from private.identity_marks where hash in (repeat('b', 64), repeat('c', 64), repeat('d', 64))),
  array[repeat('c', 64)], 'identity marks: 1 year after the deletion, 3 for a ban');
select ok(exists (select 1 from private.identity_marks where user_id = (select ed from ids)),
  'the marks of an account that still exists stay');
select is((select count(*) from private.deleted_identities where user_id = (select jo from kept)), 0::bigint,
  'digests of a kept account: gone a year after the deletion');
select is((select identities from private.account_deletions where user_id = (select jo from kept)), '{}'::jsonb,
  'and what the record says of them');
select ok((select count(*) > 0 from private.deleted_identities where user_id = (select kim from kept)),
  'a banned one''s stay 3 years');
select ok(exists (select 1 from private.account_deletions where user_id = (select jo from kept)),
  'the record itself stays with the kept account');
select is((select array_agg(reference order by reference) from private.support_requests),
  array['DR-NEW001', 'DR-OLD002'], 'support: 3 years after the last exchange');
select is((select count(*) from private.support_messages), 1::bigint, 'with their messages');
select is((select array_agg(id order by id) from public.purchase_events), array['evt-new'], 'purchase events: 10 years');
select is((select array_agg(transaction_id) from private.purchase_credits), array['tx-refunded'],
  'purchase credits: 10 years after the last change');
select is((select (counts ->> 'reports')::int + (counts ->> 'purchase_events')::int from purged), 2,
  'the counts say what went');
select ok(exists (select 1 from cron.job where jobname = 'privacy-purge' and command like '%purge_expired%'),
  'it runs every day');

-- MARK: The audit log stays append-only

select throws_ok('delete from private.admin_audit', 'P0001', 'the audit log is append-only',
  'nobody else deletes from it');
insert into private.admin_audit (actor, action, created_at) values ('mod@drafft.test', 'user.search', now() - interval '2 years');
select throws_ok($$delete from private.admin_audit where created_at < now() - interval '1 year'$$, 'P0001',
  'the audit log is append-only', 'not even a row past its period, outside the purge');
select set_config('drafft.purging', 'on', true);
select throws_ok($$delete from private.admin_audit where created_at > now() - interval '1 year'$$, 'P0001',
  'the audit log is append-only', 'the purge''s setting deletes nothing within its period');
select throws_ok($$update private.admin_audit set reason = 'edited'$$, 'P0001', 'the audit log is append-only',
  'nor edits anything');
select set_config('drafft.purging', '', true);
select throws_ok('truncate private.admin_audit', 'P0001', 'the audit log is append-only', 'nor truncates');

-- MARK: Dead letters

insert into private.outbox (event, payload, failed_at, created_at) values
  ('support.created', '{"id": 1}', now() - interval '31 days', now() - interval '32 days'),
  ('support.created', '{"id": 2}', now() - interval '29 days', now() - interval '30 days');
do $$ begin execute (select command from cron.job where jobname = 'outbox-cleanup'); end $$;
select is((select array_agg(payload ->> 'id') from private.outbox where event = 'support.created'), array['2'],
  'a failed event goes 30 days after it failed');

select ok(not has_function_privilege('authenticated', 'private.purge_expired()', 'execute')
  and not has_function_privilege('service_role', 'private.purge_expired()', 'execute'), 'only the job runs the purge');

select * from finish();
rollback;
