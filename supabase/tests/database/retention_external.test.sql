-- Retained accounts, ended chats and banned accounts' selfies (20260930000201): when each is due, and the daily
-- job queueing them once for db-events.
begin;
create extension if not exists pgtap with schema extensions;
select plan(22);

create function pg_temp.person(p_email text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id)
  values (v_id, p_email, 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  update public.profiles set onboarded_at = now(), birthdate = '1990-01-01' where id = v_id;
  return v_id;
end $$;

-- ana, bo, cy: members; rep: reported then deleted; ban: banned then deleted; held: on hold, deleted.
create temp table ids as select pg_temp.person('ana@keep.test') as ana, pg_temp.person('bo@keep.test') as bo,
  pg_temp.person('cy@keep.test') as cy, pg_temp.person('rep@keep.test') as rep,
  pg_temp.person('ban@keep.test') as ban, pg_temp.person('held@keep.test') as held;

-- MARK: Chats are tracked from their end

insert into public.matches (user_a, user_b) select least(ana, bo), greatest(ana, bo) from ids;
insert into public.matches (user_a, user_b) select least(ana, cy), greatest(ana, cy) from ids;
create temp table m as select
  (select id from public.matches, ids where user_a = least(ana, bo) and user_b = greatest(ana, bo)) as ab,
  (select id from public.matches, ids where user_a = least(ana, cy) and user_b = greatest(ana, cy)) as ac;

select is((select count(*) from private.chat_retention where match_id in (select ab from m union select ac from m)), 0::bigint,
  'an active chat is not tracked');
update public.matches set ended_at = now() - interval '13 months' where id = (select ab from m);
select is((select ended_at from private.chat_retention where match_id = (select ab from m)), now() - interval '13 months',
  'an ended match is tracked from its end');
delete from auth.users where id = (select cy from ids);
select is((select ended_at from private.chat_retention where match_id = (select ac from m)), now(),
  'a chat that ends with an erased account too, from the erasure (its channel outlives the match row)');
select ok(public.chat_erase_due((select ab from m)), 'ended over a year ago: due');
select ok(not public.chat_erase_due((select ac from m)), 'ended now: not yet');

-- MARK: When a kept account's case is closed

insert into public.reports (reporter, reported, reason) select ana, rep, 'spam' from ids;
update public.profiles set moderation = 'review' where id = (select held from ids);
update public.profiles set moderation = 'banned' where id = (select ban from ids);
select public.retain_deleted_account(rep), public.retain_deleted_account(ban), public.retain_deleted_account(held) from ids;

select is(private.retained_case_closed_at((select rep from ids)), null, 'a report still open: the case is open');
select is(private.retained_case_closed_at((select held from ids)), null, 'a hold in force: open');
select is(private.retained_case_closed_at((select ban from ids)), now(), 'banned: closed from the ban, or the deletion when later');
select is(private.retained_case_closed_at((select ana from ids)), null, 'an account not kept has no case');

update public.reports set handled_at = now() - interval '3 days' where reported = (select rep from ids);
update public.profiles set deleted_at = now() - interval '2 years' where id = (select rep from ids);
select is(private.retained_case_closed_at((select rep from ids)), now() - interval '3 days',
  'the report handled: closed then, after the deletion');
update public.reports set handled_at = now() - interval '13 months' where reported = (select rep from ids);
select ok(public.retained_account_due((select rep from ids)), 'closed over a year ago: due');

update public.profiles set deleted_at = now() - interval '2 years' where id = (select ban from ids);
update private.moderation_log set created_at = now() - interval '14 months' where user_id = (select ban from ids);
select ok(public.retained_account_due((select ban from ids)), 'banned 14 months ago: due');
update public.profiles set deleted_at = now() - interval '2 years' where id = (select held from ids);
update private.moderation_log set created_at = now() - interval '2 years' where user_id = (select held from ids);
select ok(not public.retained_account_due((select held from ids)), 'still on hold, however long ago: never due');

-- MARK: A banned account's selfies

insert into private.selfie_checks (user_id, path) select ban, ban || '/s.jpg' from ids;
select ok(public.banned_selfies_due((select ban from ids)), 'banned over 6 months ago: its selfies are due');
update private.moderation_log set created_at = now() - interval '5 months' where user_id = (select ban from ids);
select ok(not public.banned_selfies_due((select ban from ids)), 'banned 5 months ago: kept for an appeal');
update private.moderation_log set created_at = now() - interval '7 months' where user_id = (select ban from ids);

-- MARK: Queueing, once

select is(private.queue_retention_purges(), '{"accounts": 1, "chats": 1, "selfies": 1}'::jsonb,
  'the job queues what is due');
select is((select array_agg(event || ' ' || coalesce(payload ->> 'userId', payload ->> 'matchId') order by event)
    from private.outbox where event in ('account.purge', 'chat.erase', 'selfie.expired')),
  (select array['account.purge ' || rep, 'chat.erase ' || ab, 'selfie.expired ' || ban] from ids, m),
  'one event each: the reported account, the old chat, the banned account''s selfies');
select is(private.queue_retention_purges(), '{"accounts": 0, "chats": 0, "selfies": 0}'::jsonb,
  'the next day: nothing queued twice while they are on their way');
update private.outbox set failed_at = now() - interval '8 days', created_at = now() - interval '9 days'
  where event = 'chat.erase';
select is(private.queue_retention_purges() -> 'chats', '1'::jsonb, 'a week after a failure, it is queued again');

select public.chat_erased((select ab from m));
select ok(not public.chat_erase_due((select ab from m)), 'an erased chat is no longer due');

select ok(exists (select 1 from cron.job where jobname = 'retention-purge-external'), 'the job runs every day');
select ok(not has_function_privilege('authenticated', 'public.retained_account_due(uuid)', 'execute')
  and not has_function_privilege('authenticated', 'public.chat_erased(uuid)', 'execute')
  and has_function_privilege('service_role', 'public.chat_erased(uuid)', 'execute')
  and has_function_privilege('service_role', 'public.banned_selfies_due(uuid)', 'execute'),
  'db-events only');

select * from finish();
rollback;
