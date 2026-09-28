-- Upcoming sessions end with the match or the account: cancelled at an unmatch, a block, a ban and just
-- before a deletion. The other person always gets session.auto_cancelled (one neutral push), never the
-- usual session.cancelled; the chat card only for a ban, while the chat exists.
begin;
create extension if not exists pgtap with schema extensions;
select plan(19);

create function pg_temp.person(p_email text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id)
  values (v_id, p_email, 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  return v_id;
end $$;

create function pg_temp.login(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

-- A match between two people, with an accepted session tomorrow and a pending one next week.
create function pg_temp.pair(p_a uuid, p_b uuid) returns uuid language plpgsql as $$
declare
  v_match uuid;
begin
  insert into public.matches (user_a, user_b) values (least(p_a, p_b), greatest(p_a, p_b)) returning id into v_match;
  insert into public.sessions (match_id, proposer_id, sport_id, options, chosen_at, status) values
    (v_match, p_a, 'running', array[now() + interval '1 day'], now() + interval '1 day', 'accepted'),
    (v_match, p_b, 'running', array[now() + interval '7 days'], null, 'pending'),
    (v_match, p_a, 'running', array[now() - interval '3 days'], now() - interval '3 days', 'accepted');
  return v_match;
end $$;

create function pg_temp.statuses(p_match uuid) returns text language sql as $$
  select string_agg(status::text, ',' order by coalesce(chosen_at, options[1])) from public.sessions where match_id = p_match;
$$;

create function pg_temp.cancel_events(p_match uuid) returns bigint language sql as $$
  select count(*) from private.outbox where event = 'session.cancelled' and payload ->> 'matchId' = p_match::text;
$$;

-- session.auto_cancelled events of a match, as "recipient:chat" (chat when a card goes to the chat).
create function pg_temp.auto_events(p_match uuid) returns text language sql as $$
  select coalesce(string_agg((payload ->> 'to') || ':' || (payload ->> 'chatFrom' is not null), ',' order by id), '')
  from private.outbox where event = 'session.auto_cancelled' and payload ->> 'matchId' = p_match::text;
$$;

grant execute on all functions in schema pg_temp to authenticated;
create temp table ids as select pg_temp.person('ana@test.dev') as ana, pg_temp.person('bo@test.dev') as bo,
  pg_temp.person('cy@test.dev') as cy, pg_temp.person('di@test.dev') as di, pg_temp.person('ed@test.dev') as ed,
  pg_temp.person('fa@test.dev') as fa;
grant select on ids to authenticated;
create temp table m as select
  pg_temp.pair((select ana from ids), (select bo from ids)) as unmatched,
  pg_temp.pair((select cy from ids), (select di from ids)) as blocked,
  pg_temp.pair((select ed from ids), (select fa from ids)) as banned,
  pg_temp.pair((select ana from ids), (select fa from ids)) as deleted;
grant select on m to authenticated;

-- MARK: Unmatch and block

set local role authenticated;
select pg_temp.login((select ana from ids));
select public.unmatch((select unmatched from m));
select pg_temp.login((select cy from ids));
select public.block_user((select di from ids));
reset role;

select is(pg_temp.statuses((select unmatched from m)), 'accepted,cancelled,cancelled',
  'an unmatch cancels the upcoming sessions, not the past ones');
select is(pg_temp.statuses((select blocked from m)), 'accepted,cancelled,cancelled', 'so does a block');
select is(pg_temp.cancel_events((select unmatched from m)) + pg_temp.cancel_events((select blocked from m)), 0::bigint,
  'no session.cancelled (it names the person) for an ended match');
select is(pg_temp.auto_events((select unmatched from m)),
  (select bo::text || ':false,' || bo::text || ':false' from ids),
  'the person unmatched gets the neutral push for each upcoming session, without a chat card');
select is(pg_temp.auto_events((select blocked from m)),
  (select di::text || ':false,' || di::text || ':false' from ids), 'so does the person blocked');
select is((select count(*) from private.outbox where event = 'match.ended'
    and payload ->> 'matchId' in ((select unmatched::text from m), (select blocked::text from m))), 2::bigint,
  'the match itself still ends as before');

set local role authenticated;
select pg_temp.login((select ana from ids));
select is((select count(*) from public.upcoming_sessions()), 2::bigint, 'only the match still open shows sessions');
reset role;

-- MARK: Ban

select public.set_moderation((select ed from ids), 'review');
select is(pg_temp.statuses((select banned from m)), 'accepted,accepted,pending', 'a review hold keeps the sessions');
select public.set_moderation((select ed from ids), 'banned');
select is(pg_temp.statuses((select banned from m)), 'accepted,cancelled,cancelled', 'a ban cancels them');
select is(pg_temp.cancel_events((select banned from m)), 0::bigint, 'no session.cancelled naming the account');
select is(pg_temp.auto_events((select banned from m)),
  (select fa::text || ':true,' || fa::text || ':true' from ids),
  'the other person gets the neutral push, and the chat card since the chat stays');
select is((select count(*) from private.outbox where event = 'session.auto_cancelled'
    and payload ->> 'matchId' = (select banned::text from m) and payload ->> 'language' = 'en'
    and payload ->> 'timezone' = 'UTC' and (payload ->> 'notify')::boolean and payload ? 'at'),
  2::bigint, 'with the language, time zone and setting the push needs');
select is(current_setting('drafft.session_actor', true), '', 'the actor is not left behind for the transaction');
select public.set_moderation((select ed from ids), null);
select is(pg_temp.statuses((select banned from m)), 'accepted,cancelled,cancelled', 'lifting the ban brings none back');

-- MARK: Deletion

create temp table deleted_sessions as select id from public.sessions where match_id = (select deleted from m);
select is(pg_temp.statuses((select deleted from m)), 'accepted,accepted,pending', 'before the deletion');
delete from auth.users where id = (select fa from ids);
select is((select count(*) from public.sessions where id in (select id from deleted_sessions)), 0::bigint,
  'a deleted account takes its sessions');
select is(pg_temp.cancel_events((select deleted from m)), 0::bigint, 'without an event db-events could not handle');
select is(pg_temp.auto_events((select deleted from m)),
  (select ana::text || ':false,' || ana::text || ':false' from ids),
  'the other person still gets the neutral push, emitted before the cascade');
select is(current_setting('drafft.session_quiet', true), '', 'the quiet flag is not left behind');

select * from finish();
rollback;
