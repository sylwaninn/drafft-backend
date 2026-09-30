-- Statements of reasons and access to conversations (20260930000401): each decision by a person is recorded
-- with its reason category and queued for the member; reading a conversation needs a reason and a basis, or an
-- admin's override; viewing selfies needs a reason.
begin;
create extension if not exists pgtap with schema extensions;
select plan(62);

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

create function pg_temp.audits() returns bigint language sql as $$ select count(*) from private.admin_audit $$;

create temp table ids as select pg_temp.person('ana@reason.test') as ana, pg_temp.person('bo@reason.test') as bo,
  pg_temp.person('cy@reason.test') as cy, pg_temp.person('di@reason.test') as di, pg_temp.person('ed@reason.test') as ed;
insert into private.staff (email, role) values ('mod@drafft.test', 'moderator'), ('boss@drafft.test', 'admin'),
  ('sup@drafft.test', 'support');

-- MARK: Categories

-- The same list as notices.ts (reasonCopy): a category the emails can't word would fail every statement.
select is((select array_agg(e ->> 'id' order by e ->> 'id') from jsonb_array_elements(public.admin_reason_categories('sup@drafft.test')) e),
  array['evasion', 'fake_account', 'harassment', 'hate', 'identity_check', 'impersonation', 'other', 'photo_guidelines',
    'privacy', 'scam_commercial', 'sexual_content', 'underage', 'violence_illegal'], 'a fixed list of categories');
select ok(public.admin_reason_categories('sup@drafft.test') @> '[{"id": "harassment", "termsAnchor": "community"},
    {"id": "underage", "termsAnchor": "eligibility"}, {"id": "identity_check", "termsAnchor": "moderation"},
    {"id": "other", "termsAnchor": null}]',
  'each with the section of the terms it falls under, by its anchor on the page');

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
select is((select user_id::text || ' ' || kind || ' ' || category || ' ' || terms_anchor || ' ' || language
    from public.moderation_decision((select max(id) from private.moderation_decisions))),
  (select ana::text || ' account_review harassment community fr' from ids),
  'db-events reads it with the section of the terms and the person''s language');

select public.admin_set_hold('mod@drafft.test', ana, 'banned', 'insults again', 'harassment') from ids;
select is(pg_temp.decisions((select ana from ids)), 'account_review:harassment,account_banned:harassment',
  'turned into a ban: a second statement');
select public.admin_set_hold('mod@drafft.test', ana, 'banned', 'insults again', 'harassment') from ids;
select is(pg_temp.decisions((select ana from ids)), 'account_review:harassment,account_banned:harassment',
  'another hold again states nothing, even with a reason');
select public.admin_set_hold('boss@drafft.test', ana, null, 'appeal accepted') from ids;
select is(pg_temp.decisions((select ana from ids)), 'account_review:harassment,account_banned:harassment',
  'lifting it states nothing (the "you''re back" email says it)');

select is(pg_temp.hint(format($$select public.admin_set_hold('mod@drafft.test', %L, 'selfie', 'celebrity photos')$$,
  (select bo from ids))), 'category_required', 'a statement without a category: refused');
select is((select moderation from public.profiles where id = (select bo from ids)), null, 'and nothing is applied');
select public.admin_set_hold('mod@drafft.test', bo, 'selfie', 'photos look like a celebrity', 'identity_check') from ids;
select is((select count(*) from private.outbox where event = 'moderation.decision' and payload ? 'repeat'), 0::bigint,
  'a first selfie request is not a repeat (account.moderation pushes it)');
create temp table asked as select count(*) as events from private.outbox where event = 'account.moderation';
select public.admin_set_hold('mod@drafft.test', bo, 'selfie', 'still waiting', 'fake_account',
  'Please take the selfie in good light.') from ids;
select is(pg_temp.decisions((select bo from ids)), 'account_selfie:identity_check,account_selfie:fake_account',
  'a selfie asked again with a reason: a second statement');
select is((select category || ' ' || details from private.moderation_decisions where id = (select max(id) from private.moderation_decisions)),
  'fake_account Please take the selfie in good light.', 'with the new reason and note');
select ok(exists (select 1 from private.outbox o where o.event = 'moderation.decision'
    and o.payload = jsonb_build_object('id', (select max(id) from private.moderation_decisions), 'repeat', true)),
  'queued as a repeat, so db-events pushes it');
select is((select moderation::text from public.profiles where id = (select bo from ids)), 'selfie', 'the state stays');
select is((select count(*) from private.outbox where event = 'account.moderation'), (select events from asked),
  'and no state change is queued');
select public.admin_set_hold('mod@drafft.test', bo, 'selfie', 'still waiting') from ids;
select is(pg_temp.decisions((select bo from ids)), 'account_selfie:identity_check,account_selfie:fake_account',
  'the same selfie again without a reason states nothing');
select is(pg_temp.hint(format($$select public.admin_set_hold('mod@drafft.test', %L, 'banned', 'x', 'rude')$$, (select cy from ids))),
  'invalid_category', 'an unknown category is refused');
select is(pg_temp.hint(format($$select public.admin_set_hold('mod@drafft.test', %L, 'banned', 'x', 'other', %L)$$,
  (select cy from ids), repeat('x', 1001))), 'details_too_long', 'a note over 1000 characters is refused, not cut');
select is((select moderation from public.profiles where id = (select cy from ids)), null, 'and nothing is applied');
create temp table before as select pg_temp.audits() as audits;
select is(pg_temp.hint(format($$select public.admin_set_hold('mod@drafft.test', %L, null, 'lift', 'rude')$$, (select cy from ids))),
  'invalid_category', 'checked even when nothing is stated');
select is(pg_temp.audits(), (select audits from before), 'nothing is written to the audit log either');

-- MARK: Photos

insert into public.profile_media (user_id, key, position, width, height)
  select cy, 'u/' || cy || '/photos/a.jpg', 0, 800, 1000 from ids
  union all select cy, 'u/' || cy || '/photos/b.jpg', 1, 800, 1000 from ids;
create temp table photos as select id as a from public.profile_media where key like '%/a.jpg';
select is(pg_temp.hint(format($$select public.admin_review_media('mod@drafft.test', %L, false, 'nudity')$$,
  (select a from photos))), 'category_required', 'a photo refused without a category: refused');
select is((select status::text from public.profile_media where id = (select a from photos)), 'pending', 'the photo is untouched');
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
select is(pg_temp.hint(format($$select public.admin_decide_photo('mod@drafft.test', %L, 'x', null, null, 'rude')$$,
  (select a from photos))), 'invalid_category', 'decide_photo checks the category first');

-- MARK: Reports

insert into public.reports (reporter, reported, reason) select ana, ed, 'harassment' from ids;
select public.admin_close_report('mod@drafft.test', (select id from public.reports where reported = (select ed from ids)),
  'insults confirmed', 'review', 'harassment');
select is(pg_temp.decisions((select ed from ids)), 'account_review:harassment', 'a report closed with a hold: stated');
insert into public.reports (reporter, reported, reason) select bo, cy, 'spam' from ids;
select is(pg_temp.hint(format($$select public.admin_close_report('mod@drafft.test', %L, 'spam', 'review', 'rude')$$,
  (select id from public.reports where reported = (select cy from ids)))), 'invalid_category', 'close_report too');
select is((select handled_at from public.reports where reported = (select cy from ids)), null, 'the report stays open');
insert into public.media_flags (user_id, context, key, verdict) select cy, 'chat', 'u/' || cy || '/chat/x.jpg', 'review' from ids;
select is(pg_temp.hint(format($$select public.admin_decide_flags('mod@drafft.test', array[%s], 'x', 'review', null, 'rude')$$,
  (select id from public.media_flags where user_id = (select cy from ids)))), 'invalid_category', 'decide_flags too');
select public.admin_decide_flags('mod@drafft.test', array[id], 'nudity in a chat', 'review', null, 'sexual_content')
  from public.media_flags where user_id = (select cy from ids);
select is(pg_temp.decisions((select cy from ids)), 'photo_refused:sexual_content,account_review:sexual_content',
  'flags decided with a hold: stated with its category');

-- MARK: Conversations

insert into public.matches (user_a, user_b) select least(ana, ed), greatest(ana, ed) from ids;
insert into public.matches (user_a, user_b) select least(bo, di), greatest(bo, di) from ids;
update public.profiles set moderation = null where id in (select bo from ids union select di from ids);
create temp table m as select
  (select id from public.matches, ids where user_a = least(ana, ed) and user_b = greatest(ana, ed)) as reported,
  (select id from public.matches, ids where user_a = least(bo, di) and user_b = greatest(bo, di)) as plain;

select is(public.admin_conversation_access('boss@drafft.test', (select reported from m)) -> 'basis', '["report", "hold"]'::jsonb,
  'a report between them, and an account on hold');
select is(public.admin_conversation_access('mod@drafft.test', (select reported from m)) -> 'basis', '["report"]'::jsonb,
  'a hold the reader put themself doesn''t count for them');
select is(public.admin_conversation_access('mod@drafft.test', (select plain from m)),
  '{"basis": [], "canOverride": false}'::jsonb, 'nothing for an ordinary match');
select is(public.admin_conversation_access('boss@drafft.test', (select plain from m)) ->> 'canOverride', 'true',
  'an admin may override');
select is(pg_temp.hint(format($$select public.admin_conversation_access('mod@drafft.test', %L)$$, gen_random_uuid())),
  'not_found', 'an unknown match: not_found');

select throws_ok(format($$select public.admin_log('mod@drafft.test', 'conversation.view', %L, %L, 'opened in sophros')$$,
    (select ana from ids), (select reported from m)),
  'P0001', 'say why you read this conversation', 'the old default is not a reason');
select lives_ok(format($$select public.admin_log('mod@drafft.test', 'conversation.view', %L, %L, 'report: checking the insults')$$,
    (select ana from ids), (select reported from m)), 'a reason and a basis: read');
select is((select details -> 'basis' from private.admin_audit where action = 'conversation.view' order by id desc limit 1),
  '["report"]'::jsonb, 'the log says on what basis');
select throws_ok(format($$select public.admin_log('mod@drafft.test', 'conversation.view', %L, %L, 'curious about this one')$$,
    (select bo from ids), (select plain from m)),
  'P0001', 'no report, help request or hold concerns this conversation', 'no basis: refused');
select throws_ok(format($$select public.admin_log('mod@drafft.test', 'conversation.view', %L, %L, 'police request 2026-114', true)$$,
    (select bo from ids), (select plain from m)),
  'P0001', 'not allowed', 'a moderator can''t override');
select is(pg_temp.hint(format($$select public.admin_log('boss@drafft.test', 'conversation.view', %L, %L, 'police request', true)$$,
    (select bo from ids), (select plain from m))), 'override_basis_required', 'an override says why: legal request or safety');
select lives_ok(format($$select public.admin_log('boss@drafft.test', 'conversation.view', %L, %L, 'police request 2026-114', true,
    p_override_basis => 'legal_request')$$, (select bo from ids), (select plain from m)), 'an admin can, with a reason');
select is((select details - 'basis' from private.admin_audit where action = 'conversation.view' order by id desc limit 1),
  '{"override": true, "overrideBasis": "legal_request", "category": null}'::jsonb, 'and the override is logged, with why');

insert into private.support_requests (reference, user_id, email, topic, message, created_at, handled_at)
  select 'DR-RSN000', bo, 'bo@reason.test', 'Help', 'Old and handled', now() - interval '91 days', now() - interval '80 days' from ids;
select is(public.admin_conversation_access('mod@drafft.test', (select plain from m)) -> 'basis', '[]'::jsonb,
  'a help request handled and over 90 days old is no basis');
insert into private.support_requests (reference, user_id, email, topic, message, created_at)
  select 'DR-RSN001', bo, 'bo@reason.test', 'Help', 'Someone keeps writing', now() - interval '91 days' from ids;
select is(public.admin_conversation_access('mod@drafft.test', (select plain from m)) -> 'basis', '["support"]'::jsonb,
  'one still open is, however old');

select is(pg_temp.hint(format($$select public.admin_log('mod@drafft.test', 'message.delete', %L, %L, 'insult', false, 'harassment')$$,
  (select ana from ids), (select reported from m))), 'invalid_target', 'a removal names the message');
select is(pg_temp.hint(format($$select public.admin_log('mod@drafft.test', 'message.delete', %L, %L, 'insult', false, 'harassment')$$,
  (select bo from ids), (select reported from m) || '/msg-1')), 'invalid_target', 'and its author is one of the two members');
select is(pg_temp.hint(format($$select public.admin_log('mod@drafft.test', 'message.delete', null, %L, 'insult', false, 'harassment')$$,
  (select reported from m) || '/msg-1')), 'invalid_target', 'always named');
select is(pg_temp.hint(format($$select public.admin_log('mod@drafft.test', 'message.delete', %L, %L, 'insult')$$,
  (select ana from ids), (select reported from m) || '/msg-1')), 'category_required', 'with a category');
select is(pg_temp.hint(format($$select public.admin_log('mod@drafft.test', 'conversation.view', null, 'm', 'reading')$$)),
  'not_found', 'a target that is no match: not_found');
select public.admin_log('mod@drafft.test', 'message.delete', ana, (select reported from m) || '/msg-1', 'insult',
  false, 'harassment', 'This message insulted the person you were talking to.') from ids;
select is((select kind || ' ' || target from private.moderation_decisions where kind = 'message_deleted'),
  'message_deleted ' || (select reported from m) || '/msg-1', 'a removed message is stated to its author');
select is((select details ->> 'category' from private.admin_audit where action = 'message.delete'), 'harassment',
  'the audit log keeps the category');

-- MARK: Selfies

select throws_ok(format($$select public.admin_selfies('mod@drafft.test', %L, ' ')$$, (select bo from ids)),
  'P0001', 'say why', 'viewing selfies needs a reason');

select ok(exists (select 1 from cron.job where jobname = 'moderation-decisions-cleanup')
  and not has_function_privilege('authenticated', 'public.moderation_decision(bigint)', 'execute')
  and has_function_privilege('service_role', 'public.admin_log(text, text, uuid, text, text, boolean, text, text, text)', 'execute'),
  'server side only, kept like the moderation log');

-- MARK: A banned account's decisions outlive it

delete from auth.users where id in (select ana from ids union select cy from ids);
select ok(not exists (select 1 from private.moderation_decisions where user_id = (select cy from ids)),
  'an account erased: its decisions go with it');
update public.profiles set moderation = 'banned' where id = (select di from ids);
delete from auth.users where id = (select di from ids);
select ok(exists (select 1 from private.moderation_decisions where user_id = (select di from ids)),
  'a banned one''s stay, for their 3 years');

select * from finish();
rollback;
