-- Statements of reasons and access to conversations (20260930000401): each decision by a person is recorded
-- with its reason category and queued for the member; reading a conversation needs a reason and a basis, or an
-- admin's override; viewing selfies needs a reason.
begin;
create extension if not exists pgtap with schema extensions;
select plan(30);

create function pg_temp.person(p_email text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id)
  values (v_id, p_email, 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  update public.profiles set language = 'fr' where id = v_id;
  return v_id;
end $$;

create function pg_temp.decisions(p_user uuid) returns text language sql as $$
  select coalesce(string_agg(kind || ':' || category, ',' order by id), '') from private.moderation_decisions
  where user_id = p_user;
$$;

create temp table ids as select pg_temp.person('ana@reason.test') as ana, pg_temp.person('bo@reason.test') as bo,
  pg_temp.person('cy@reason.test') as cy, pg_temp.person('di@reason.test') as di, pg_temp.person('ed@reason.test') as ed;
insert into private.staff (email, role) values ('mod@drafft.test', 'moderator'), ('boss@drafft.test', 'admin'),
  ('sup@drafft.test', 'support');

-- MARK: Categories

select is(jsonb_array_length(public.admin_reason_categories('sup@drafft.test')), 13, 'a fixed list of 13 categories');
select ok(public.admin_reason_categories('sup@drafft.test') @> '[{"id": "harassment", "termsSection": "community_guidelines"}]',
  'each with the part of the terms it applies');

-- MARK: Holds

select public.admin_set_hold('mod@drafft.test', ana, 'review', 'three reports this week', 'harassment',
  'Several people told us about insults in your messages.') from ids;
select is(pg_temp.decisions((select ana from ids)), 'account_review:harassment', 'a hold is recorded with its reason');
select is((select details from private.moderation_decisions where user_id = (select ana from ids)),
  'Several people told us about insults in your messages.', 'and the team''s note for the member');
select ok(exists (select 1 from private.outbox o join private.moderation_decisions d on (o.payload ->> 'id')::bigint = d.id
  where o.event = 'moderation.decision' and d.user_id = (select ana from ids)), 'queued for db-events');
select is((select details ->> 'category' from private.admin_audit where action = 'hold.set' and user_id = (select ana from ids)),
  'harassment', 'the audit log keeps the category');
select is((select user_id::text || ' ' || kind || ' ' || category || ' ' || language from public.moderation_decision(
    (select max(id) from private.moderation_decisions))),
  (select ana::text || ' account_review harassment fr' from ids), 'db-events reads it with the person''s language');

select public.admin_set_hold('mod@drafft.test', ana, 'banned', 'insults again', 'harassment') from ids;
select is(pg_temp.decisions((select ana from ids)), 'account_review:harassment,account_banned:harassment',
  'turned into a ban: a second statement');
select public.admin_set_hold('boss@drafft.test', ana, null, 'appeal accepted') from ids;
select is(pg_temp.decisions((select ana from ids)), 'account_review:harassment,account_banned:harassment',
  'lifting it states nothing (the "you''re back" email says it)');

select public.admin_set_hold('mod@drafft.test', bo, 'selfie', 'photos look like a celebrity') from ids;
select is(pg_temp.decisions((select bo from ids)), 'account_selfie:other',
  'no category (a sophros from before): told as other');
select throws_ok(format($$select public.admin_set_hold('mod@drafft.test', %L, 'banned', 'x', 'rude')$$, (select cy from ids)),
  'P0001', 'unknown reason category', 'an unknown category is refused');
select is((select moderation from public.profiles where id = (select cy from ids)), null, 'and nothing is applied');

-- MARK: Photos

insert into public.profile_media (user_id, key, position, width, height)
  select cy, 'u/' || cy || '/photos/a.jpg', 0, 800, 1000 from ids
  union all select cy, 'u/' || cy || '/photos/b.jpg', 1, 800, 1000 from ids;
create temp table photos as select id as a from public.profile_media where key like '%/a.jpg';
select public.admin_review_media('mod@drafft.test', (select a from photos), false, 'nudity', 'sexual_content');
select is(pg_temp.decisions((select cy from ids)), 'photo_refused:sexual_content', 'a refused photo is stated');
select public.admin_review_media('mod@drafft.test', (select a from photos), false, 'again', 'sexual_content');
select is(pg_temp.decisions((select cy from ids)), 'photo_refused:sexual_content', 'once: refusing it again says nothing new');
select public.admin_review_media('mod@drafft.test', id, true) from public.profile_media where key like '%/b.jpg';
select is(pg_temp.decisions((select cy from ids)), 'photo_refused:sexual_content', 'an approval says nothing');

insert into public.profile_media (user_id, key, position, width, height)
  select di, 'u/' || di || '/photos/c.jpg', 0, 800, 1000 from ids;
select public.admin_decide_photo('mod@drafft.test', (select id from public.profile_media where key like '%/c.jpg'),
  'someone else''s photo', 'selfie', null, 'impersonation', 'This photo appears elsewhere under another name.');
select is(pg_temp.decisions((select di from ids)), 'photo_refused:impersonation,account_selfie:impersonation',
  'a photo refused with a hold: both stated, same reason');

-- MARK: Reports

insert into public.reports (reporter, reported, reason) select ana, ed, 'harassment' from ids;
select public.admin_close_report('mod@drafft.test', (select id from public.reports where reported = (select ed from ids)),
  'insults confirmed', 'review', 'harassment');
select is(pg_temp.decisions((select ed from ids)), 'account_review:harassment', 'a report closed with a hold: stated');

-- MARK: Conversations

insert into public.matches (user_a, user_b) select least(ana, ed), greatest(ana, ed) from ids;
insert into public.matches (user_a, user_b) select least(bo, di), greatest(bo, di) from ids;
update public.profiles set moderation = null where id in (select bo from ids union select di from ids);
create temp table m as select
  (select id from public.matches, ids where user_a = least(ana, ed) and user_b = greatest(ana, ed)) as reported,
  (select id from public.matches, ids where user_a = least(bo, di) and user_b = greatest(bo, di)) as plain;

select is(public.admin_conversation_access('mod@drafft.test', (select reported from m)) -> 'basis', '["report", "hold"]'::jsonb,
  'a report between them, and an account on hold');
select is(public.admin_conversation_access('mod@drafft.test', (select plain from m)),
  '{"basis": [], "canOverride": false}'::jsonb, 'nothing for an ordinary match');

select throws_ok(format($$select public.admin_log('mod@drafft.test', 'conversation.view', %L, %L, 'opened in sophros')$$,
    (select ana from ids), (select reported from m)),
  'P0001', 'say why you read this conversation', 'the old default is not a reason');
select lives_ok(format($$select public.admin_log('mod@drafft.test', 'conversation.view', %L, %L, 'report: checking the insults')$$,
    (select ana from ids), (select reported from m)), 'a reason and a basis: read');
select is((select details -> 'basis' from private.admin_audit where action = 'conversation.view' order by id desc limit 1),
  '["report", "hold"]'::jsonb, 'the log says on what basis');
select throws_ok(format($$select public.admin_log('mod@drafft.test', 'conversation.view', %L, %L, 'curious about this one')$$,
    (select bo from ids), (select plain from m)),
  'P0001', 'no report, help request or hold concerns this conversation', 'no basis: refused');
select throws_ok(format($$select public.admin_log('mod@drafft.test', 'conversation.view', %L, %L, 'police request 2026-114', true)$$,
    (select bo from ids), (select plain from m)),
  'P0001', 'not allowed', 'a moderator can''t override');
select lives_ok(format($$select public.admin_log('boss@drafft.test', 'conversation.view', %L, %L, 'police request 2026-114', true)$$,
    (select bo from ids), (select plain from m)), 'an admin can, with a reason');
select is((select details ->> 'override' from private.admin_audit where action = 'conversation.view' order by id desc limit 1),
  'true', 'and the override is logged');

insert into private.support_requests (reference, user_id, email, topic, message)
  select 'DR-RSN001', bo, 'bo@reason.test', 'Help', 'Someone keeps writing' from ids;
select is(public.admin_conversation_access('mod@drafft.test', (select plain from m)) -> 'basis', '["support"]'::jsonb,
  'a help request from either member is a basis');

select public.admin_log('mod@drafft.test', 'message.delete', ana, (select reported from m) || '/msg-1', 'insult',
  false, 'harassment', 'This message insulted the person you were talking to.') from ids;
select is((select kind || ' ' || target from private.moderation_decisions where kind = 'message_deleted'),
  'message_deleted ' || (select reported from m) || '/msg-1', 'a removed message is stated to its author');

-- MARK: Selfies

select throws_ok(format($$select public.admin_selfies('mod@drafft.test', %L, ' ')$$, (select bo from ids)),
  'P0001', 'say why', 'viewing selfies needs a reason');

select ok(exists (select 1 from cron.job where jobname = 'moderation-decisions-cleanup')
  and not has_function_privilege('authenticated', 'public.moderation_decision(bigint)', 'execute')
  and has_function_privilege('service_role', 'public.admin_log(text, text, uuid, text, text, boolean, text, text)', 'execute'),
  'server side only, kept like the moderation log');

select * from finish();
rollback;
