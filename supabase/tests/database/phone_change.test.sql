-- One pending phone change per number: a new code for a number cancels other accounts' pending ones.
-- Run with `supabase test db`.

begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

create function pg_temp.account() returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id)
  values (v_id, v_id || '@test.dev', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  return v_id;
end $$;

create temp table people as select pg_temp.account() as first, pg_temp.account() as second;

-- Both ask for a code for the same number, the second one last.
update auth.users set phone_change = '33612345678', phone_change_token = 'first-token', phone_change_sent_at = now()
  where id = (select first from people);
update auth.users set phone_change = '33612345678', phone_change_token = 'second-token', phone_change_sent_at = now()
  where id = (select second from people);

select is((select phone_change from auth.users where id = (select first from people)), '',
  'the earlier pending change to the number is cancelled');
select is((select phone_change_token from auth.users where id = (select second from people)), 'second-token',
  'the latest one stays');

-- A new code for the second account (Resend) keeps its own pending change.
update auth.users set phone_change_token = 'second-token-2' where id = (select second from people);
select is((select phone_change from auth.users where id = (select second from people)), '33612345678',
  'a Resend keeps the account''s own pending change');

select * from finish();
rollback;
