-- Staff live events: a queue change sends a private broadcast on staff:queues, naming the queue only;
-- the app's roles can neither read nor send on a staff topic.
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

create function pg_temp.person(p_email text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id)
  values (v_id, p_email, 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  return v_id;
end $$;

create function pg_temp.staff_events(p_queue text) returns bigint language sql as $$
  select count(*) from realtime.messages
  where topic = 'staff:queues' and event = 'queue' and private and payload ->> 'queue' = p_queue;
$$;

create temp table ids as select pg_temp.person('sam@test.dev') as sam, pg_temp.person('eve@test.dev') as eve;
grant select on ids to authenticated;

insert into public.reports (reporter, reported, reason) select sam, eve, (enum_range(null::public.report_reason))[1] from ids;
select is(pg_temp.staff_events('reports'), 1::bigint, 'a new report is broadcast to staff');

update public.reports set handled_at = now();
select is(pg_temp.staff_events('reports'), 2::bigint, 'a handled report too');

update public.profiles set moderation = (enum_range(null::public.moderation_state))[1] where id = (select eve from ids);
select is(pg_temp.staff_events('accounts'), 1::bigint, 'a hold is broadcast to staff');

select is(
  (select payload - 'queue' - 'event' - 'private' - 'id' from realtime.messages
   where topic = 'staff:queues' order by inserted_at desc limit 1),
  '{}'::jsonb, 'the payload names the queue and nothing personal');

insert into realtime.messages (topic, extension, event, payload, private)
values ('user:' || (select eve from ids), 'broadcast', 'probe', '{}', true);

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', (select eve from ids), 'role', 'authenticated')::text, true);
select set_config('realtime.topic', 'staff:queues', true);
select is((select count(*) from realtime.messages where topic = 'staff:queues'), 0::bigint,
  'a signed-in person reads nothing on the staff topic');
select throws_ok($$insert into realtime.messages (topic, extension, event, payload, private)
  values ('staff:queues', 'broadcast', 'queue', '{}', true)$$, '42501', null, 'nor sends on it');
select set_config('realtime.topic', 'user:' || (select eve from ids), true);
select ok((select count(*) from realtime.messages where topic = 'user:' || (select eve from ids)) > 0,
  'their own topic still works');
reset role;

select ok(not has_function_privilege('authenticated', 'private.staff_queue_changed()', 'execute'),
  'the trigger function is not callable by the app');

select * from finish();
rollback;
