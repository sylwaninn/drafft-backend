-- Support by email (20260930000501): a verified reply joins its thread and reopens it, anything else is a new
-- request (linked and acknowledged only when verified), each email once, within limits; sophros tells the
-- member's messages from the team's.
begin;
create extension if not exists pgtap with schema extensions;
select plan(42);

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

insert into private.staff (email, role) values ('sup@drafft.test', 'support');
create temp table lea as select gen_random_uuid() as id;
insert into auth.users (id, email, aud, role, instance_id)
  select id, 'lea@inbound.test', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000' from lea;
update public.profiles set language = 'fr' where id = (select id from lea);
create temp table ref as
  select public.create_support_request((select id from lea), 'lea@inbound.test', 'fr', 'Help', 'Stuck') as reference;
create temp table req as select id from private.support_requests where reference = (select reference from ref);
select public.admin_reply_support('sup@drafft.test', (select id from req), 'Try again?', true, gen_random_uuid());

create function pg_temp.received(p_from text, p_body text, p_reference text, p_id text, p_verified boolean default true)
returns jsonb language sql as $$
  select public.receive_support_email(p_from, 'Re: Help', p_body, p_reference, p_id, '{}', p_verified);
$$;

select ok(not has_function_privilege('authenticated', 'public.receive_support_email(text, text, text, text, text, jsonb, boolean)', 'execute')
  and not has_function_privilege('anon', 'public.receive_support_email(text, text, text, text, text, jsonb, boolean)', 'execute')
  and has_function_privilege('service_role', 'public.receive_support_email(text, text, text, text, text, jsonb, boolean)', 'execute'),
  'the support-inbound function only');

-- MARK: A reply in its thread

select ok((select handled_at is not null from private.support_requests where id = (select id from req)),
  'the request was closed by the team''s reply');
select is(pg_temp.received('Lea@Inbound.test', 'Still stuck', (select reference from ref), '<m1@mail.test>') - 'reference',
  '{"outcome": "appended", "truncated": false}'::jsonb, 'a verified reply with its reference, from its address: appended');
select is((select handled_at from private.support_requests where id = (select id from req)), null,
  'the request reopens');
select is((select direction || ' ' || author || ' ' || body from private.support_messages
  where request_id = (select id from req) order by id desc limit 1), 'in lea@inbound.test Still stuck',
  'the member''s message, as received');
select ok((select sent_at is not null from private.support_messages where request_id = (select id from req)
  and direction = 'in'), 'nothing to send: received');
select is((select count(*) from private.outbox where event = 'support.received'), 1::bigint, 'the team gets a copy');
select is((select direction from public.support_reply((select max(id) from private.support_messages))), 'in',
  'db-events reads who wrote it');

select is(pg_temp.received('lea@inbound.test', 'Still stuck', (select reference from ref), '<m1@mail.test>') ->> 'outcome',
  'duplicate', 'the same email twice: taken once');
select is(pg_temp.received('lea@inbound.test', 'Still stuck', (select reference from ref), '<m1@mail.test>') ->> 'reference',
  (select reference from ref), 'with the reference it went to');
select is((select count(*) from private.support_messages where request_id = (select id from req) and direction = 'in'),
  1::bigint, 'one message');

select is(pg_temp.received('lea@inbound.test', repeat('a', 9000), (select reference from ref), '<m2@mail.test>') ->> 'truncated',
  'true', 'longer than a message holds: kept up to 8000 characters, and said so');

-- The account's current email, not the one the request was written from.
update auth.users set email = 'lea2@inbound.test' where id = (select id from lea);
select is(pg_temp.received('lea2@inbound.test', 'From my new address', (select reference from ref), null) ->> 'outcome',
  'appended', 'the account''s current email may answer too');
update auth.users set email = 'lea@inbound.test' where id = (select id from lea);

-- A received message is never sent, nor changed as if it were.
select public.support_reply_sent((select max(id) from private.support_messages), 'boom');
select is((select error from private.support_messages where id = (select max(id) from private.support_messages)), null,
  'support_reply_sent leaves a received message alone');
select throws_ok(format($$update private.support_messages set sent_at = null where id = %s$$,
  (select max(id) from private.support_messages)), '23514', null, 'a received message is always received');

-- MARK: Not verified

select is(pg_temp.received('lea@inbound.test', 'Forged', (select reference from ref), '<m5@mail.test>', false) ->> 'outcome',
  'created', 'an unverified sender never joins a thread, even with its reference and address');
select is((select coalesce(user_id::text, 'none') || ' ' || (context ->> 'verified') || ' ' || (context ->> 'referenceMentioned')
    from private.support_requests where message = 'Forged'),
  'none false ' || (select reference from ref), 'a new request, linked to no account, the reference kept for the team');

-- MARK: Anything else is a new request

select is(pg_temp.received('mallory@inbound.test', 'Let me in', (select reference from ref), '<m3@mail.test>') ->> 'outcome',
  'created', 'another address with that reference: never into the thread');
select is((select context ->> 'referenceMentioned' from private.support_requests where email = 'mallory@inbound.test'),
  (select reference from ref), 'the reference it mentioned is kept for the team');
select is((select user_id from private.support_requests where email = 'mallory@inbound.test'), null,
  'no account with that address: none linked');

select is(public.receive_support_email('lea@inbound.test', 'Re: RE: Fwd: Mon compte [DR-ABC234]', 'New question', null,
  '<m4@mail.test>', '{}', true) ->> 'outcome', 'created', 'no reference: a new request');
select is((select topic || ' ' || language || ' ' || (user_id = (select id from lea))::text || ' ' || (context ->> 'source')
    || ' ' || signed_out::text from private.support_requests where message = 'New question'),
  'Mon compte fr true email false', 'the subject as its topic, linked to the account with that address, in its language');
select is(private.email_topic('Re: [DR-ABC234]', 'fr'), 'Message par e-mail', 'an empty subject: a topic in their language');
select is(private.email_topic('', null), 'Message by email', 'English otherwise');
select is(pg_temp.received('lea@inbound.test', 'Unknown', 'DR-ZZZZZZ', null) ->> 'outcome', 'created',
  'an unknown reference: a new request');
select is(public.receive_support_email('x@inbound.test', 'Login broken', '', null, null, '{}', true) ->> 'outcome', 'created',
  'no text: the subject is the message (a screenshot alone)');
select is((select message from private.support_requests where email = 'x@inbound.test'), 'Login broken', 'as written');
select is(public.receive_support_email('y@inbound.test', 'Long', repeat('b', 5000), null, null, '{}', true) ->> 'truncated',
  'true', 'a new request holds 4000 characters, and says so');

select is(pg_temp.hint($$select pg_temp.received('not an address', 'x', null, null)$$), 'invalid_email', 'a sender is required');
select is(pg_temp.hint($$select public.receive_support_email('x@inbound.test', '', '', null, null, '{}', true)$$),
  'empty_message', 'something written is required');

-- The context stays within its 2000 bytes, whatever was sent.
select is(public.receive_support_email('z@inbound.test', 'Big', 'Hello', null, null,
  jsonb_build_object('authentication', repeat('é', 900), 'attachments', jsonb_build_array(repeat('ü', 300))), true) ->> 'outcome',
  'created', 'a context too big is trimmed, never refused');
select ok((select octet_length(context::text) <= 2000 and not context ? 'authentication' from private.support_requests
  where email = 'z@inbound.test'), 'the authentication goes first');

-- MARK: Limits

select pg_temp.received('lea@inbound.test', 'Again ' || i, (select reference from ref), null) from generate_series(1, 7) i;
select is(pg_temp.hint($$select pg_temp.received('lea@inbound.test', 'Once more', (select reference from ref), null)$$),
  'too_many_requests', '10 an hour into one request');
select pg_temp.received('spam@inbound.test', 'Spam ' || i, null, null, false) from generate_series(1, 5) i;
select is(pg_temp.hint($$select pg_temp.received('spam@inbound.test', 'Spam 6', null, '<spam6@mail.test>', false)$$),
  'too_many_requests', '5 new requests an hour per address');
select ok(not exists (select 1 from private.support_inbound where message_id = '<spam6@mail.test>'),
  'a refused email isn''t taken: a retry isn''t a duplicate');
select is((select count(*) from private.support_requests where signed_out), 0::bigint,
  'email requests never count against the app''s signed-out form');

select is((select r -> 'replies' -> 0 ->> 'direction' || (r -> 'replies' -> 1 ->> 'direction')
  from jsonb_array_elements(public.admin_support('sup@drafft.test', false, (select reference from ref))) r),
  'outin', 'sophros sees who wrote each message');

-- MARK: A reply the outbox gave up on

select public.admin_reply_support('sup@drafft.test', (select id from req), 'Reply ' || i, false, gen_random_uuid())
  from generate_series(1, 3) i;
create temp table sent as select array_agg(id order by id) as ids from private.support_messages
  where request_id = (select id from req) and direction = 'out';
create function pg_temp.give_up(p_message bigint, p_discard boolean default false) returns void language sql as $$
  update private.outbox set failed_at = case when not p_discard then now() end,
      last_error = case when not p_discard then 'support reply: connection reset' end,
      discarded_at = case when p_discard then now() end, discard_reason = case when p_discard then 'duplicate' end
    where event = 'support.reply' and payload ->> 'id' = p_message::text;
$$;
create function pg_temp.error(p_message bigint) returns text language sql as $$
  select error from private.support_messages where id = p_message;
$$;
select public.support_reply_sent(ids[2], 'resend: 422 invalid to address') from sent;
select public.support_reply_sent(ids[3]) from sent;
select pg_temp.give_up(i) from sent, unnest(ids[1:3]) i;
select pg_temp.give_up(ids[4], true) from sent;
select is(pg_temp.error((select ids[1] from sent)), 'support reply: connection reset',
  'a reply the outbox gave up on, with nothing recorded, is marked failed: never left sending');
select is(pg_temp.error((select ids[2] from sent)), 'resend: 422 invalid to address', 'the error db-events recorded stays');
select is(pg_temp.error((select ids[3] from sent)), null, 'a reply already sent is left alone');
select is(pg_temp.error((select ids[4] from sent)), 'discarded: duplicate', 'so is one discarded in sophros');
select public.support_reply_sent(ids[1]) from sent;
select is((select error is null and sent_at is not null from private.support_messages where id = (select ids[1] from sent)),
  true, 'a replay that sends it clears the error');

select * from finish();
rollback;
