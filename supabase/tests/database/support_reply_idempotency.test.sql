-- A support reply sent twice with the same key (a double click, a retried request) is one message and
-- one email; without a key, as before.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

insert into private.staff (email, role) values ('sup@drafft.test', 'support');
create temp table lea as select gen_random_uuid() as id;
insert into auth.users (id, email, aud, role, instance_id)
  select id, 'lea@support.test', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000' from lea;
create temp table ref as
  select public.create_support_request((select id from lea), 'lea@support.test', 'fr', 'Help', 'Stuck') as reference;
create temp table req as
  select id from private.support_requests where reference = (select reference from ref);
create temp table k as select gen_random_uuid() as key;

create function pg_temp.replies() returns bigint language sql as $$
  select count(*) from private.support_messages where request_id = (select id from req);
$$;
create function pg_temp.emails() returns bigint language sql as $$
  select count(*) from private.outbox o join private.support_messages m on (o.payload ->> 'id')::bigint = m.id
  where o.event = 'support.reply' and m.request_id = (select id from req);
$$;

select lives_ok($$select public.admin_reply_support('sup@drafft.test', (select id from req), 'Bonjour', false, (select key from k))$$,
  'a reply with a key');
select lives_ok($$select public.admin_reply_support('sup@drafft.test', (select id from req), 'Bonjour', true, (select key from k))$$,
  'the same key again succeeds');
select is(pg_temp.replies(), 1::bigint, 'one message');
select is(pg_temp.emails(), 1::bigint, 'one email');
select is((select handled_at from private.support_requests where id = (select id from req)), null,
  'the duplicate changes nothing (it asked to close)');
select is((select count(*) from private.admin_audit where action = 'support.reply' and target =
  (select reference from private.support_requests where id = (select id from req))), 1::bigint, 'one audit entry');

select public.admin_reply_support('sup@drafft.test', (select id from req), 'Encore', true, gen_random_uuid());
select is(pg_temp.replies(), 2::bigint, 'a new key is a new reply');

select * from finish();
rollback;
