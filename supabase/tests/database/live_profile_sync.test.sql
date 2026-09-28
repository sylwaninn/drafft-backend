-- Live profile sync: an update of public.profiles broadcasts `profile` on the owner's private topic with
-- the changed column names only; internal columns send nothing.
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

create function pg_temp.person(p_email text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id)
  values (v_id, p_email, 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  return v_id;
end $$;

create temp table ids as select pg_temp.person('ana@test.dev') as ana, pg_temp.person('bob@test.dev') as bob;

create function pg_temp.events(p_user uuid) returns bigint language sql as $$
  select count(*) from realtime.messages where topic = 'user:' || p_user and event = 'profile' and private;
$$;

-- Every message of one transaction shares inserted_at and ids are random uuids: look a message up by its
-- fields rather than by order.
create function pg_temp.sent(p_user uuid, p_fields jsonb) returns boolean language sql as $$
  select exists (select from realtime.messages
    where topic = 'user:' || p_user and event = 'profile' and private and payload -> 'fields' = p_fields);
$$;

select is(pg_temp.events((select ana from ids)), 0::bigint, 'creating the profile sends nothing');

update public.profiles set paused = not paused where id = (select ana from ids);
select ok(pg_temp.sent((select ana from ids), '["paused"]'::jsonb), 'a pause names the field');

update public.profiles set language = 'fr', notify_likes = not notify_likes where id = (select ana from ids);
select ok(pg_temp.sent((select ana from ids), '["language", "notify_likes"]'::jsonb),
  'language and settings are named together, sorted');

update public.profiles set bio = 'Morning runs', neighborhood = 'Croix-Rousse' where id = (select ana from ids);
select ok(pg_temp.sent((select ana from ids), '["bio", "neighborhood"]'::jsonb), 'card fields too');

select is(
  (select payload - 'fields' - 'event' - 'private' - 'id' from realtime.messages
   where topic = 'user:' || (select ana from ids) and event = 'profile'
     and payload -> 'fields' = '["bio", "neighborhood"]'::jsonb),
  '{}'::jsonb, 'the payload carries names, not values');

select is(pg_temp.events((select ana from ids)), 3::bigint, 'one event per update');

update public.profiles set last_active_at = now() + interval '1 minute' where id = (select ana from ids);
update public.profiles set bio = bio where id = (select ana from ids);
select is(pg_temp.events((select ana from ids)), 3::bigint, 'internal columns and no-op updates send nothing');

select is(pg_temp.events((select bob from ids)), 0::bigint, 'nothing reaches anyone else');

select ok(not has_function_privilege('authenticated', 'private.broadcast_profile()', 'execute'),
  'the trigger function is not callable by the app');

select * from finish();
rollback;
