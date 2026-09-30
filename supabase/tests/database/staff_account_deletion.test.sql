-- Deleting an account on the member's request (20260930000601): admins only, with a reason and a reference,
-- audited, the addresses and language taken before anything changes and kept outside the queue, one deletion at
-- a time, the real outcome recorded.
begin;
create extension if not exists pgtap with schema extensions;
select plan(33);

insert into private.staff (email, role) values ('adm@drafft.test', 'admin'), ('sup@drafft.test', 'support');

create function pg_temp.person(p_email text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id)
  values (v_id, p_email, 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  update public.profiles set language = 'de' where id = v_id;
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

create temp table ids as select pg_temp.person('ana@delete.test') as ana, pg_temp.person('bo@delete.test') as bo,
  pg_temp.person('cy@delete.test') as cy, pg_temp.person('di@delete.test') as di;
insert into public.reports (reporter, reported, reason, details) select ana, bo, 'spam', 'ads' from ids;
update public.profiles set moderation = 'banned' where id = (select cy from ids);
-- Ana wrote from another address (she lost access to hers); di has no email at all.
create temp table ref as
  select public.create_support_request(null, 'ana.new@delete.test', 'de', 'Delete my account', 'Please') as reference;
update auth.users set email = null where id = (select di from ids);

-- MARK: Who and what

select ok(not has_function_privilege('authenticated', 'public.admin_delete_account(text, uuid, text, text)', 'execute')
  and not has_function_privilege('anon', 'public.admin_delete_account(text, uuid, text, text)', 'execute')
  and not has_function_privilege('authenticated', 'public.admin_account_deletion_preview(text, uuid, text)', 'execute')
  and not has_function_privilege('anon', 'public.admin_account_deletion_preview(text, uuid, text)', 'execute')
  and not has_function_privilege('authenticated', 'public.staff_deletion(bigint)', 'execute')
  and has_function_privilege('service_role', 'public.admin_delete_account(text, uuid, text, text)', 'execute')
  and has_function_privilege('service_role', 'public.staff_deletion_done(bigint, text)', 'execute'),
  'server side only');
select throws_ok($$select public.admin_delete_account('sup@drafft.test', (select ana from ids), 'Asked by email', 'email')$$,
  'P0001', 'not allowed', 'support staff can''t delete an account');
select throws_ok($$select public.admin_account_deletion_preview('sup@drafft.test', (select ana from ids))$$,
  'P0001', 'not allowed', 'nor preview one');
select is(pg_temp.hint($$select public.admin_delete_account('adm@drafft.test', (select ana from ids), '  ', 'email')$$),
  'reason_required', 'a reason is required');
select is(pg_temp.hint(format($$select public.admin_delete_account('adm@drafft.test', %L, %L, 'email')$$,
  (select ana from ids), repeat('x', 1001))), 'reason_required', 'of 1000 characters at most');
select is(pg_temp.hint($$select public.admin_delete_account('adm@drafft.test', (select ana from ids), 'Asked', 'DR-12')$$),
  'invalid_reference', 'a reference that looks like one');
select is(pg_temp.hint($$select public.admin_delete_account('adm@drafft.test', (select ana from ids), 'Asked', 'DR-ZZZZZZ')$$),
  'unknown_reference', 'and that exists');
select is(pg_temp.hint($$select public.admin_delete_account('adm@drafft.test', gen_random_uuid(), 'Asked', 'email')$$),
  'not_found', 'an account that exists');

-- MARK: Preview

select is(public.admin_account_deletion_preview('adm@drafft.test', (select ana from ids)),
  '{"status": "ready", "outcome": "erased", "emails": ["ana@delete.test"], "emailed": true}'::jsonb,
  'nothing against it: erased, confirmed to its address');
select is(public.admin_account_deletion_preview('adm@drafft.test', (select ana from ids), (select reference from ref)) -> 'emails',
  '["ana.new@delete.test", "ana@delete.test"]'::jsonb, 'with a request from another address: that one too');
select is(public.admin_account_deletion_preview('adm@drafft.test', (select bo from ids)) - 'emails' - 'emailed',
  '{"status": "ready", "outcome": "kept", "basis": "report"}'::jsonb, 'under an open report: kept for safety, and why');
select is(public.admin_account_deletion_preview('adm@drafft.test', (select cy from ids)) ->> 'basis', 'ban', 'banned: kept');
select is(public.admin_account_deletion_preview('adm@drafft.test', (select di from ids)) - 'outcome',
  '{"status": "ready", "emails": [], "emailed": false}'::jsonb, 'no address at all: no email (the team is told)');
select is(pg_temp.hint($$select public.admin_account_deletion_preview('adm@drafft.test', gen_random_uuid())$$), 'not_found',
  'an unknown account');

-- MARK: Deleting

select is(public.admin_delete_account('adm@drafft.test', (select ana from ids), 'Wrote from a new address, phone confirmed',
  lower((select reference from ref))),
  '{"expected": "erased", "emails": ["ana.new@delete.test", "ana@delete.test"], "emailed": true}'::jsonb,
  'queued, the outcome expected and the addresses said');
create temp table d as select * from private.staff_deletions where user_id = (select ana from ids);
select is((select payload from private.outbox where event = 'account.staff_delete'),
  jsonb_build_object('id', (select id from d)), 'the queue carries only the deletion''s id: no address');
select is((select reference || ' ' || language || ' ' || array_to_string(emails, ',') from d),
  (select reference from ref) || ' de ana.new@delete.test,ana@delete.test', 'the reference normalised, language and addresses kept');
select is((select reason || ' ' || target || ' ' || (details ->> 'expected') from private.admin_audit
  where action = 'account.delete' and user_id = (select ana from ids)),
  'Wrote from a new address, phone confirmed ' || (select reference from ref) || ' erased', 'audited');
select is(pg_temp.hint($$select public.admin_delete_account('adm@drafft.test', (select ana from ids), 'Again', 'email')$$),
  'already_requested', 'one deletion at a time');
select is(public.admin_account_deletion_preview('adm@drafft.test', (select ana from ids)), '{"status": "pending"}'::jsonb,
  'the preview says it is on its way');
select is((select user_id::text || ' ' || language from public.staff_deletion((select id from d))),
  (select ana::text || ' de' from ids), 'db-events reads it');

-- db-events, after running it: the real outcome, then the addresses cleared.
select public.staff_deletion_done((select id from d), 'kept');
select public.staff_deletion_done((select id from d), 'erased');
select is((select outcome from private.staff_deletions where id = (select id from d)), 'kept', 'the outcome recorded once');
select is((select details ->> 'outcome' from private.admin_audit where action = 'account.deleted' and user_id = (select ana from ids)),
  'kept', 'in the audit log too: what happened, not what was expected');
select is(pg_temp.hint(format('select public.staff_deletion_done(%s, ''gone'')', (select id from d))), 'invalid_outcome',
  'erased or kept, nothing else');
select public.staff_deletion_emailed((select id from d));
select is((select cardinality(emails) from private.staff_deletions where id = (select id from d)), 0, 'the addresses go once emailed');

-- A deletion whose event failed no longer blocks a new one.
update private.outbox set failed_at = now() where event = 'account.staff_delete';
select is(public.admin_account_deletion_preview('adm@drafft.test', (select ana from ids)) ->> 'status', 'ready',
  'a failed deletion is no longer pending');

select is(public.admin_delete_account('adm@drafft.test', (select bo from ids), 'Phone confirmed', 'EMAIL') ->> 'expected',
  'kept', 'a reported account: expected kept');
select is(public.admin_delete_account('adm@drafft.test', (select di from ids), 'Phone confirmed', 'email') ->> 'emailed',
  'false', 'no address: said to sophros');
update public.profiles set deleted_at = now() where id = (select bo from ids);
select is(pg_temp.hint($$select public.admin_delete_account('adm@drafft.test', (select bo from ids), 'Again', 'email')$$),
  'already_deleted', 'a kept account is deleted already');
select is(public.admin_account_deletion_preview('adm@drafft.test', (select bo from ids)), '{"status": "deleted"}'::jsonb,
  'and the preview says so');

-- MARK: Addresses don't outlive 30 days

update private.staff_deletions set requested_at = now() - interval '31 days';
do $$ begin execute (select command from cron.job where jobname = 'staff-deletions-cleanup'); end $$;
select is((select count(*) from private.staff_deletions), 0::bigint, 'the rows go after 30 days, addresses with them');
select ok(exists (select 1 from private.admin_audit where action = 'account.delete'), 'the audit log keeps what was done');
select ok((select erasure from private.outbox_policies where event = 'account.staff_delete'), 'an erasure: never dropped when failed');

select * from finish();
rollback;
