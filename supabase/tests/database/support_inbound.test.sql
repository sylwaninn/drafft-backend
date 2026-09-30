-- Support by email (20260930000501): a reply joins its thread and reopens it, anything else is a new request,
-- each email once, within limits; sophros tells the member's messages from the team's.
begin;
create extension if not exists pgtap with schema extensions;
select plan(20);

insert into private.staff (email, role) values ('sup@drafft.test', 'support');
create temp table lea as select gen_random_uuid() as id;
insert into auth.users (id, email, aud, role, instance_id)
  select id, 'lea@inbound.test', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000' from lea;
update public.profiles set language = 'fr' where id = (select id from lea);
create temp table ref as
  select public.create_support_request((select id from lea), 'lea@inbound.test', 'fr', 'Help', 'Stuck') as reference;
create temp table req as select id from private.support_requests where reference = (select reference from ref);
select public.admin_reply_support('sup@drafft.test', (select id from req), 'Try again?', true, gen_random_uuid());

create function pg_temp.received(p_from text, p_body text, p_reference text, p_id text) returns jsonb language sql as $$
  select public.receive_support_email(p_from, 'Re: Help', p_body, p_reference, p_id, '{}');
$$;

-- MARK: A reply in its thread

select is(pg_temp.received('Lea@Inbound.test', 'Still stuck', (select reference from ref), '<m1@mail.test>') - 'reference',
  '{"outcome": "appended", "truncated": false}'::jsonb, 'a reply with its reference, from its address: appended');
select is((select handled_at from private.support_requests where id = (select id from req)), null,
  'the request reopens');
select is((select direction || ' ' || author || ' ' || body from private.support_messages
  where request_id = (select id from req) order by id desc limit 1), 'in lea@inbound.test Still stuck',
  'the member''s message, as received');
select ok((select sent_at is not null from private.support_messages where request_id = (select id from req)
  and direction = 'in'), 'nothing to send: received');
select is((select count(*) from private.outbox where event = 'support.received'), 1::bigint, 'the team gets a copy');
select is((select count(*) from private.outbox where event = 'support.reply'
  and (payload ->> 'id')::bigint in (select id from private.support_messages where direction = 'in')), 0::bigint,
  'never emailed back to the member');

select is(pg_temp.received('lea@inbound.test', 'Still stuck', (select reference from ref), '<m1@mail.test>') ->> 'outcome',
  'duplicate', 'the same email twice: taken once');
select is((select count(*) from private.support_messages where request_id = (select id from req) and direction = 'in'),
  1::bigint, 'one message');

select is(pg_temp.received('lea@inbound.test', repeat('a', 9000), (select reference from ref), '<m2@mail.test>') ->> 'truncated',
  'true', 'longer than a message holds: kept up to 8000 characters, and said so');

-- MARK: Anything else is a new request

select is(pg_temp.received('mallory@inbound.test', 'Let me in', (select reference from ref), '<m3@mail.test>') ->> 'outcome',
  'created', 'another address with that reference: never into the thread');
select is((select context ->> 'referenceMentioned' from private.support_requests where email = 'mallory@inbound.test'),
  (select reference from ref), 'the reference it mentioned is kept for the team');
select is((select user_id from private.support_requests where email = 'mallory@inbound.test'), null,
  'no account with that address: none linked');

select is(pg_temp.received('lea@inbound.test', 'New question', null, '<m4@mail.test>') ->> 'outcome', 'created',
  'no reference: a new request');
select is((select topic || ' ' || language || ' ' || (user_id = (select id from lea))::text || ' ' || (context ->> 'source')
  from private.support_requests where message = 'New question'), 'email fr true email',
  'topic email, linked to the account with that address, in its language');
select is((select count(*) from private.outbox where event = 'support.created'), 3::bigint,
  'acknowledged and copied to the team like the form');
select is(pg_temp.received('lea@inbound.test', 'Unknown', 'DR-ZZZZZZ', null) ->> 'outcome', 'created',
  'an unknown reference: a new request');

select throws_ok($$select pg_temp.received('not an address', 'x', null, null)$$, 'P0001', 'no sender address',
  'a sender is required');
select throws_ok($$select public.receive_support_email('x@inbound.test', '', '', null, null, '{}')$$, 'P0001',
  'nothing written', 'something written is required');

-- MARK: Limits

select pg_temp.received('lea@inbound.test', 'Again ' || i, (select reference from ref), null) from generate_series(1, 8) i;
select throws_ok($$select pg_temp.received('lea@inbound.test', 'Once more', (select reference from ref), null)$$,
  'P0001', 'too many messages, try again later', '10 an hour into one request');

select is((select r -> 'replies' -> 0 ->> 'direction' || (r -> 'replies' -> 1 ->> 'direction')
  from jsonb_array_elements(public.admin_support('sup@drafft.test', false, (select reference from ref))) r),
  'outin', 'sophros sees who wrote each message');

select * from finish();
rollback;
