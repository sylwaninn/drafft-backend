-- The forms reach the team: support requests (with limits), data exports, reports (and when they hold an
-- account), and the email events for a photo approved on a second look and a hold lifted.
begin;
create extension if not exists pgtap with schema extensions;
select plan(15);

create function pg_temp.person(p_email text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id)
  values (v_id, p_email, 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  -- Reports need an onboarded account (20260928000002).
  update public.profiles set onboarded_at = now() where id = v_id;
  return v_id;
end $$;

create function pg_temp.login(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

grant execute on all functions in schema pg_temp to authenticated;
create temp table ids as select pg_temp.person('ana@test.dev') as ana, pg_temp.person('bo@test.dev') as bo,
  pg_temp.person('cy@test.dev') as cy, pg_temp.person('di@test.dev') as di, pg_temp.person('ed@test.dev') as ed;
grant select on ids to authenticated;

-- MARK: Support

select matches(public.create_support_request((select ana from ids), 'ana@test.dev', 'fr', 'Account check', 'Why?'),
  '^DR-[A-HJ-NP-Z2-9]{6}$', 'a readable reference');
select is((select payload ? 'id' from private.outbox where event = 'support.created' order by id desc limit 1), true,
  'the acknowledgement and the team copy are queued');
select public.create_support_request((select ana from ids), 'ana@test.dev', 'fr', 't', 'm') from generate_series(1, 4);
select throws_ok(format($$select public.create_support_request(%L, 'ana@test.dev', 'fr', 't', 'm')$$, (select ana from ids)),
  'P0001', 'too many messages, try again later', '5 an hour per account');
select lives_ok($$select public.create_support_request(null, 'someone@else.dev', 'xx', 't', 'm')$$,
  'signed out works, unknown language falls back');
select is((select language from private.support_requests where email = 'someone@else.dev'), 'en', 'to English');
select ok(not has_function_privilege('authenticated', 'public.create_support_request(uuid, text, text, text, text, jsonb)', 'execute')
    and not has_function_privilege('anon', 'public.create_support_request(uuid, text, text, text, text, jsonb)', 'execute'),
  'only through the support function');

-- MARK: Data export

set local role authenticated;
select pg_temp.login((select bo from ids));
create temp table first_ask as select public.request_data_export() as at;
select is(public.request_data_export(), (select at from first_ask), 'asking again returns the open request');
reset role;
select is((select count(*) from private.data_requests where user_id = (select bo from ids)), 1::bigint, 'stored once');

-- MARK: Reports

set local role authenticated;
select pg_temp.login((select ana from ids));
select public.report_user((select ed from ids), 'spam', 'sells stuff');
reset role;
select is((select count(*) from private.outbox where event = 'report.created'
    and payload ->> 'id' in (select id::text from public.reports where reported = (select ed from ids))),
  1::bigint, 'the team hears of each report');
select is((select moderation::text from public.profiles where id = (select ed from ids)), null, 'one report holds nobody');

set local role authenticated;
select pg_temp.login((select bo from ids));
select public.report_user((select ed from ids), 'fake');
select pg_temp.login((select cy from ids));
select public.report_user((select ed from ids), 'harassment');
reset role;
select is((select moderation::text from public.profiles where id = (select ed from ids)), 'review',
  'three people in 30 days: held for review');

set local role authenticated;
select pg_temp.login((select ana from ids));
select public.report_user((select di from ids), 'underage');
reset role;
select is((select note from private.moderation_log where user_id = (select di from ids) order by id desc limit 1),
  'reported as underage', 'someone reported as underage is held at once');

-- MARK: Emails on good news

insert into public.profile_media (user_id, key, position, width, height, status, review_requested_at)
  values ((select ana from ids), 'u/' || (select ana from ids) || '/photos/x.jpg', 0, 100, 100, 'pending', now());
select public.review_media((select id from public.profile_media where user_id = (select ana from ids)), true);
select is((select payload ->> 'userId' from private.outbox where event = 'media.approved_on_review' order by id desc limit 1),
  (select ana from ids)::text, 'a photo approved on a second look is emailed');
select is((select review_requested_at from public.profile_media where user_id = (select ana from ids)), null,
  'and leaves the queue');

select public.set_moderation((select di from ids), null);
select is((select payload ->> 'previous' from private.outbox where event = 'account.moderation' order by id desc limit 1),
  'review', 'a lifted hold is emailed (db-events)');

select * from finish();
rollback;
