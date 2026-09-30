-- Deleting an account on the member's request (20260930000601): admins only, with a reason and a reference,
-- audited, the email and language taken before anything changes, one deletion at a time.
begin;
create extension if not exists pgtap with schema extensions;
select plan(16);

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

create temp table ids as select pg_temp.person('ana@delete.test') as ana, pg_temp.person('bo@delete.test') as bo;
insert into public.reports (reporter, reported, reason, details) select ana, bo, 'spam', 'ads' from ids;
create temp table ref as
  select public.create_support_request((select ana from ids), 'ana@delete.test', 'de', 'Delete my account', 'Please')
    as reference;

-- MARK: Who and what

select throws_ok($$select public.admin_delete_account('sup@drafft.test', (select ana from ids), 'Asked by email', 'email')$$,
  'P0001', 'not allowed', 'support staff can''t delete an account');
select throws_ok($$select public.admin_account_deletion_preview('sup@drafft.test', (select ana from ids))$$,
  'P0001', 'not allowed', 'nor preview one');
select throws_ok($$select public.admin_delete_account('adm@drafft.test', (select ana from ids), '  ', 'email')$$,
  'P0001', 'say why, in 1000 characters at most', 'a reason is required');
select throws_ok($$select public.admin_delete_account('adm@drafft.test', (select ana from ids), 'Asked', 'DR-ZZZZZZ')$$,
  'P0001', 'give the support reference (DR-XXXXXX) or "email"', 'a reference that exists');
select throws_ok($$select public.admin_delete_account('adm@drafft.test', gen_random_uuid(), 'Asked', 'email')$$,
  'P0001', 'no such account', 'an account that exists');

-- MARK: Preview

select is(public.admin_account_deletion_preview('adm@drafft.test', (select ana from ids)) - 'email',
  '{"outcome": "erase", "basis": null, "deleted": false, "pending": false}'::jsonb, 'nothing against it: erased');
select is(public.admin_account_deletion_preview('adm@drafft.test', (select bo from ids)) ->> 'outcome', 'keep',
  'under an open report: kept for safety');
select is(public.admin_account_deletion_preview('adm@drafft.test', (select bo from ids)) ->> 'basis', 'report',
  'and why');

-- MARK: Deleting

select is(public.admin_delete_account('adm@drafft.test', (select ana from ids), 'Asked by email from the account''s address',
  lower((select reference from ref))), '{"expected": "erase"}'::jsonb, 'queued, the outcome expected said');
select is((select payload - 'userId' from private.outbox where event = 'account.staff_delete'),
  jsonb_build_object('email', 'ana@delete.test', 'language', 'de', 'reference', (select reference from ref)),
  'the email and language taken now, the reference normalised');
select is((select reason || ' ' || target || ' ' || (details ->> 'expected') from private.admin_audit
  where action = 'account.delete' and user_id = (select ana from ids)),
  'Asked by email from the account''s address ' || (select reference from ref) || ' erase', 'audited');
select throws_ok($$select public.admin_delete_account('adm@drafft.test', (select ana from ids), 'Again', 'email')$$,
  'P0001', 'a deletion of this account is on its way', 'one deletion at a time');
select is(public.admin_account_deletion_preview('adm@drafft.test', (select ana from ids)) ->> 'pending', 'true',
  'the preview says it is on its way');

select is(public.admin_delete_account('adm@drafft.test', (select bo from ids), 'Phone confirmed', 'EMAIL'),
  '{"expected": "keep"}'::jsonb, 'a reported account: expected kept');
update public.profiles set deleted_at = now() where id = (select bo from ids);
update private.outbox set delivered_at = now() where event = 'account.staff_delete';
select throws_ok($$select public.admin_delete_account('adm@drafft.test', (select bo from ids), 'Again', 'email')$$,
  'P0001', 'this account is deleted already', 'a kept account is deleted already');

select ok(not has_function_privilege('authenticated', 'public.admin_delete_account(text, uuid, text, text)', 'execute')
  and has_function_privilege('service_role', 'public.admin_delete_account(text, uuid, text, text)', 'execute'),
  'server side only');

select * from finish();
rollback;
