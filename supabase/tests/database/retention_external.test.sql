-- Retained accounts, ended chats and banned accounts' selfies (20260930000201): when each is due, the daily
-- job queueing them once for db-events, and a banned account's history outliving it.
begin;
create extension if not exists pgtap with schema extensions;
select plan(44);

create function pg_temp.person(p_email text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id)
  values (v_id, p_email, 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  update public.profiles set onboarded_at = now(), birthdate = '1990-01-01' where id = v_id;
  return v_id;
end $$;

-- ana, bo, cy, dee: members; rep: reported then deleted; ban: banned then deleted; held: on hold, deleted;
-- lift: on hold, deleted, hold lifted since.
create temp table ids as select pg_temp.person('ana@keep.test') as ana, pg_temp.person('bo@keep.test') as bo,
  pg_temp.person('cy@keep.test') as cy, pg_temp.person('dee@keep.test') as dee, pg_temp.person('rep@keep.test') as rep,
  pg_temp.person('ban@keep.test') as ban, pg_temp.person('held@keep.test') as held,
  pg_temp.person('lift@keep.test') as lift;

-- MARK: Chats are tracked from their end

insert into public.matches (user_a, user_b) select least(ana, bo), greatest(ana, bo) from ids;
insert into public.matches (user_a, user_b) select least(ana, cy), greatest(ana, cy) from ids;
insert into public.matches (user_a, user_b) select least(ana, dee), greatest(ana, dee) from ids;
create temp table m as select
  (select id from public.matches, ids where user_a = least(ana, bo) and user_b = greatest(ana, bo)) as ab,
  (select id from public.matches, ids where user_a = least(ana, cy) and user_b = greatest(ana, cy)) as ac,
  (select id from public.matches, ids where user_a = least(ana, dee) and user_b = greatest(ana, dee)) as ad;

select is((select count(*) from private.chat_retention where match_id in (select ab from m union select ac from m)), 0::bigint,
  'an active chat is not tracked');
update public.matches set ended_at = now() - interval '13 months' where id = (select ab from m);
select is((select ended_at from private.chat_retention where match_id = (select ab from m)), now() - interval '13 months',
  'an ended match is tracked from its end');
delete from auth.users where id = (select cy from ids);
select is((select ended_at from private.chat_retention where match_id = (select ac from m)), now(),
  'a chat that ends with an erased account too, from the erasure');
update public.matches set ended_at = now() - interval '11 months' where id = (select ad from m);
select ok(public.chat_erase_due((select ab from m)), 'ended over a year ago: due');
select ok(not public.chat_erase_due((select ac from m)), 'ended now: not yet');
select ok(not public.chat_erase_due((select ad from m)), 'ended 11 months ago: not yet');
delete from auth.users where id = (select dee from ids);
select is((select ended_at from private.chat_retention where match_id = (select ad from m)), now() - interval '11 months',
  'erasing an account later keeps the date the chat ended');

-- Frozen channels found in Stream by chat.sweep: only those whose match row is gone are new.
create temp table swept as select gen_random_uuid() as orphan;
select is(public.track_frozen_chats(jsonb_build_array(
    jsonb_build_object('id', (select orphan from swept), 'at', now() - interval '2 years'),
    jsonb_build_object('id', (select ab from m), 'at', now()),
    jsonb_build_object('id', null, 'at', now()))), 1, 'the sweep tracks the channels no match row knows');
select is((select ended_at from private.chat_retention where match_id = (select orphan from swept)),
  now() - interval '2 years', 'from their last update');
select is((select ended_at from private.chat_retention where match_id = (select ab from m)),
  now() - interval '13 months', 'a chat tracked already keeps its date');
select ok(exists (select 1 from private.outbox where event = 'chat.sweep'), 'the sweep is queued once, by the migration');

-- MARK: When a kept account's case is closed

insert into public.reports (reporter, reported, reason) select ana, rep, 'spam' from ids;
update public.profiles set moderation = 'review' where id in (select held from ids union select lift from ids);
update public.profiles set moderation = 'banned' where id = (select ban from ids);
select public.retain_deleted_account(rep), public.retain_deleted_account(ban), public.retain_deleted_account(held),
  public.retain_deleted_account(lift) from ids;

select is(private.retained_case_closed_at((select rep from ids)), null, 'a report still open: the case is open');
select is(private.retained_case_closed_at((select held from ids)), null, 'a hold in force: open');
select is(private.retained_case_closed_at((select ban from ids)), now(), 'banned: closed from the ban, or the deletion when later');
select is(private.retained_case_closed_at((select ana from ids)), null, 'an account not kept has no case');
update public.profiles set moderation = 'selfie' where id = (select held from ids);
select is(private.retained_case_closed_at((select held from ids)), null, 'a selfie asked for: open');

update public.reports set handled_at = now() - interval '3 days' where reported = (select rep from ids);
update public.profiles set deleted_at = now() - interval '2 years' where id = (select rep from ids);
select is(private.retained_case_closed_at((select rep from ids)), now() - interval '3 days',
  'the report handled: closed then, after the deletion');
update public.reports set handled_at = now() - interval '11 months' where reported = (select rep from ids);
select ok(not public.retained_account_due((select rep from ids)), 'closed 11 months ago: not yet');
update public.reports set handled_at = now() - interval '13 months' where reported = (select rep from ids);
select ok(public.retained_account_due((select rep from ids)), 'closed over a year ago: due');
insert into public.reports (reporter, reported, reason) select bo, rep, 'harassment' from ids;
select ok(not public.retained_account_due((select rep from ids)), 'a new report about it: no longer due');
update public.reports set handled_at = now() - interval '13 months' where reported = (select rep from ids);

update public.profiles set deleted_at = now() - interval '11 months' where id = (select ban from ids);
update private.moderation_log set created_at = now() - interval '14 months' where user_id = (select ban from ids);
select ok(not public.retained_account_due((select ban from ids)), 'banned 14 months ago, deleted 11 months ago: not yet');
update public.profiles set deleted_at = now() - interval '2 years' where id = (select ban from ids);
select ok(public.retained_account_due((select ban from ids)), 'banned 14 months ago, deleted before: due');
update public.profiles set deleted_at = now() - interval '2 years' where id = (select held from ids);
update private.moderation_log set created_at = now() - interval '2 years' where user_id = (select held from ids);
select ok(not public.retained_account_due((select held from ids)), 'still on hold, however long ago: never due');

update public.profiles set moderation = null where id = (select lift from ids);
update public.profiles set deleted_at = now() - interval '2 years' where id = (select lift from ids);
update private.moderation_log set created_at = now() - interval '13 months' where user_id = (select lift from ids);
select ok(public.retained_account_due((select lift from ids)), 'hold lifted 13 months ago: due');

-- MARK: A banned account's selfies

select ok(not public.banned_selfies_due((select ban from ids)), 'no selfie: nothing due');
insert into private.selfie_checks (user_id, path) select ban, ban || '/s.jpg' from ids;
select ok(public.banned_selfies_due((select ban from ids)), 'banned over 6 months ago: its selfies are due');
update private.moderation_log set created_at = now() - interval '5 months' where user_id = (select ban from ids);
select ok(not public.banned_selfies_due((select ban from ids)), 'banned 5 months ago: kept for an appeal');
update private.moderation_log set created_at = now() - interval '7 months' where user_id = (select ban from ids);

-- MARK: Queueing, once

select is(private.queue_retention_purges(), '{"accounts": 2, "chats": 2, "selfies": 1}'::jsonb,
  'the job queues what is due');
select is((select array_agg(event || ' ' || coalesce(payload ->> 'userId', payload ->> 'matchId') order by event, payload::text)
    from private.outbox where event in ('account.purge', 'chat.erase', 'selfie.expired')),
  (select array_agg(x order by x) from ids, m, swept,
    unnest(array['account.purge ' || rep, 'account.purge ' || lift, 'chat.erase ' || ab, 'chat.erase ' || orphan,
      'selfie.expired ' || ban]) x),
  'one event each: the kept accounts closed a year ago, the old chats, the banned account''s selfies');
select is((select count(distinct next_attempt_at) from private.outbox where event in ('account.purge', 'chat.erase', 'selfie.expired')),
  5::bigint, 'spread a second apart');
select ok((select bool_and(o.delivered_at is null and o.next_attempt_at > now() - interval '1 second') from private.outbox o
  where o.event in ('account.purge', 'chat.erase', 'selfie.expired')), 'posted by the retry loop, not at once');
select is((select counts from private.job_runs where job = 'retention-purge-external' order by id desc limit 1),
  '{"accounts": 2, "chats": 2, "selfies": 1}'::jsonb, 'the run is recorded');
select is(private.queue_retention_purges(), '{"accounts": 0, "chats": 0, "selfies": 0}'::jsonb,
  'the next day: nothing queued twice while they are on their way');

update private.outbox set failed_at = now() - interval '1 day', created_at = now() - interval '2 days'
  where event = 'chat.erase';
select is(private.queue_retention_purges() -> 'chats', '0'::jsonb, 'failed 2 days ago: not queued again yet');
update private.outbox set failed_at = null, delivered_at = now() - interval '1 day' where event = 'chat.erase';
select is(private.queue_retention_purges() -> 'chats', '0'::jsonb, 'delivered this week: not queued again');
update private.outbox set delivered_at = null, discarded_at = now() - interval '8 days', created_at = now() - interval '9 days'
  where event = 'chat.erase';
select is(private.queue_retention_purges() -> 'chats', '2'::jsonb, 'queued over a week ago and discarded: queued again');

select public.chat_erased((select ab from m));
select ok(not public.chat_erase_due((select ab from m)), 'an erased chat is no longer due');

select ok((select bool_and(erasure) and count(*) = 4 from private.outbox_policies
  where event in ('account.purge', 'chat.erase', 'selfie.expired', 'chat.sweep')), 'every one is an erasure: never dropped when failed');
select ok(exists (select 1 from cron.job where jobname = 'retention-purge-external')
  and exists (select 1 from private.watched_jobs where job = 'retention-purge-external'), 'the job runs every day, watched');
select ok(not has_function_privilege('authenticated', 'public.retained_account_due(uuid)', 'execute')
  and not has_function_privilege('authenticated', 'public.chat_erased(uuid)', 'execute')
  and not has_function_privilege('authenticated', 'public.track_frozen_chats(jsonb)', 'execute')
  and has_function_privilege('service_role', 'public.chat_erased(uuid)', 'execute')
  and has_function_privilege('service_role', 'public.track_frozen_chats(jsonb)', 'execute')
  and has_function_privilege('service_role', 'public.banned_selfies_due(uuid)', 'execute'),
  'db-events only');

-- MARK: A banned account's history outlives it

insert into private.staff_notes (user_id, author, body) select ban, 'mod@keep.test', 'banned' from ids
  union all select rep, 'mod@keep.test', 'reported' from ids;
insert into private.account_links (user_id, deleted_user_id, via) select ana, ban, 'email' from ids
  union all select ana, rep, 'phone' from ids;
insert into public.media_flags (user_id, context, key, verdict) select ban, 'chat', 'u/' || ban || '/chat/x.jpg', 'rejected' from ids
  union all select rep, 'chat', 'u/' || rep || '/chat/y.jpg', 'rejected' from ids;
delete from auth.users where id in (select ban from ids union select rep from ids);
select ok((select count(*) > 0 from private.moderation_log where user_id = (select ban from ids))
    and exists (select 1 from private.staff_notes where user_id = (select ban from ids))
    and exists (select 1 from private.account_links where deleted_user_id = (select ban from ids))
    and exists (select 1 from public.media_flags where user_id = (select ban from ids)),
  'a banned account erased: its log, notes, links and flags stay, for their 3 years');
select ok(not exists (select 1 from private.moderation_log where user_id = (select rep from ids))
    and not exists (select 1 from private.staff_notes where user_id = (select rep from ids))
    and not exists (select 1 from private.account_links where deleted_user_id = (select rep from ids)),
  'any other account: they go with it, as before');
select is((select count(*) from public.media_flags where key like 'u/' || (select rep from ids) || '/%' and user_id is null),
  1::bigint, 'its flags stay unlinked, as before');
select ok(private.banned_account((select ban from ids)), 'still counted as banned, for the purge');

select * from finish();
rollback;
