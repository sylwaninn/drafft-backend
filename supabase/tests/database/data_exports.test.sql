-- Automatic data exports (20260930000301): what an export holds, one build at a time, and the file expiring
-- after 7 days.
begin;
create extension if not exists pgtap with schema extensions;
select plan(22);

create function pg_temp.person(p_email text, p_name text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id)
  values (v_id, p_email, 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  update public.profiles set name = p_name, onboarded_at = now(), birthdate = '1990-01-01', drinks = 'socially'
    where id = v_id;
  return v_id;
end $$;

create temp table ids as select pg_temp.person('ana@export.test', 'Ana') as ana, pg_temp.person('bo@export.test', 'Bo') as bo,
  pg_temp.person('cy@export.test', 'Cy') as cy;

insert into public.profile_sports (user_id, sport_id, per_week, position) select ana, 'running', 3, 0 from ids;
insert into public.swipes (swiper, target, action, note) select ana, bo, 'superlike', 'Sunday run?' from ids;
insert into public.swipes (swiper, target, action) select bo, ana, 'like' from ids;
insert into public.matches (user_a, user_b) select least(ana, bo), greatest(ana, bo) from ids;
insert into public.blocks (blocker, blocked) select ana, cy from ids;
insert into public.reports (reporter, reported, reason, details) select ana, cy, 'spam', 'ads' from ids;
insert into public.reports (reporter, reported, reason, details) select cy, ana, 'fake', 'about ana' from ids;
insert into private.devices (user_id, install_id, model, ip) select ana, gen_random_uuid(), 'iPhone', '203.0.113.9' from ids;
insert into private.support_requests (reference, user_id, email, topic, message)
  select 'DR-EXP001', ana, 'ana@export.test', 'Help', 'A question' from ids;
insert into private.support_messages (request_id, author, body, sent_at)
  select id, 'sup@drafft.test', 'An answer', now() from private.support_requests where reference = 'DR-EXP001';

create temp table x as select public.export_data((select ana from ids)) as data;

-- MARK: What an export holds

select is((select data -> 'account' ->> 'email' from x), 'ana@export.test', 'the account, with its email');
select is((select data -> 'profile' ->> 'drinks' from x), 'socially', 'the profile row, lifestyle included');
select is((select data -> 'sports' -> 0 ->> 'sport' from x), 'running', 'sports');
select is((select data -> 'swipes' -> 0 from x) - 'createdAt' - 'opener',
  (select jsonb_build_object('to', jsonb_build_object('id', bo, 'name', 'Bo'), 'action', 'superlike', 'note', 'Sunday run?') from ids),
  'likes sent, the other person by first name');
select is((select jsonb_array_length(data -> 'swipes') from x), 1, 'not the likes received');
select is((select data -> 'matches' -> 0 -> 'with' ->> 'name' from x), 'Bo', 'matches');
select is((select data -> 'blocks' -> 0 -> 'who' ->> 'name' from x), 'Cy', 'blocks');
select is((select data -> 'reportsMade' -> 0 ->> 'details' from x), 'ads', 'reports made');
select ok((select data::text not like '%about ana%' from x), 'never the reports about them (who made them is protected)');
select is((select data -> 'devices' -> 0 ->> 'ip' from x), '203.0.113.9', 'devices and IPs');
select is((select data -> 'support' -> 0 -> 'replies' -> 0 ->> 'body' from x), 'An answer', 'help requests and replies');
select ok((select data::text not like '%sup@drafft.test%' from x), 'not the staff member''s address');
select is(public.export_data(gen_random_uuid()), null, 'an account gone: nothing');

-- MARK: One build at a time

insert into private.data_requests (user_id) select ana from ids;
create temp table r as select id from private.data_requests where user_id = (select ana from ids);
select is(public.export_begin((select id from r)), 'go', 'the first delivery claims it');
select is(public.export_begin((select id from r)), 'busy', 'another one meanwhile waits');
update private.data_requests set started_at = now() - interval '16 minutes' where id = (select id from r);
select is(public.export_begin((select id from r)), 'go', 'a build that stopped is taken back after 15 minutes');
select public.export_ready((select id from r), array[(select ana from ids) || '/' || (select id from r) || '-1.zip',
  (select ana from ids) || '/' || (select id from r) || '-2.zip']);
select is(public.export_begin((select id from r)), 'done', 'fulfilled: done');
select ok((select fulfilled_by = 'automatic' and expires_at = now() + interval '7 days' from private.data_requests
  where id = (select id from r)), 'fulfilled automatically, the file kept 7 days');

-- MARK: Expiring

update private.data_requests set expires_at = now() - interval '1 minute' where id = (select id from r);
select is(private.queue_export_expiries() + private.queue_export_expiries(), 1, 'an expired file is queued once');
select is(cardinality(public.export_files((select id from r))), 2, 'every part of it is deleted');
select public.export_file_deleted((select id from r));
select is(public.export_files((select id from r)), null, 'deleted: nothing left to delete');

select ok(not has_function_privilege('authenticated', 'public.export_data(uuid)', 'execute')
  and has_function_privilege('service_role', 'public.export_data(uuid)', 'execute')
  and exists (select 1 from storage.buckets where id = 'data-exports' and not public)
  and exists (select 1 from cron.job where jobname = 'data-exports-expire'),
  'server side only: a private bucket, the job every hour');

select * from finish();
rollback;
