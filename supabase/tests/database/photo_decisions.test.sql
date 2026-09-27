-- A person's decision on a photo (review_media) reaches its owner: a media.reviewed event for db-events
-- (refusal push, and an email after a second look), once per actual change.
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

create function pg_temp.photo(p_user uuid, p_name text, p_position int, p_second_look boolean)
returns uuid language sql as $$
  insert into public.profile_media (user_id, key, position, width, height, status, review_requested_at)
  values (p_user, 'u/' || p_user || '/photos/' || p_name || '.jpg', p_position, 100, 100, 'pending',
    case when p_second_look then now() end)
  returning id;
$$;

create temp table ids as select pg_temp.person('ana@test.dev') as ana;
create temp table photos as select
  pg_temp.photo((select ana from ids), 'a', 0, false) as refused,
  pg_temp.photo((select ana from ids), 'b', 1, true) as looked_again,
  pg_temp.photo((select ana from ids), 'c', 2, false) as approved;

create function pg_temp.reviewed(p_media uuid) returns setof jsonb language sql as $$
  select payload from private.outbox where event = 'media.reviewed' and payload ->> 'mediaId' = p_media::text order by id;
$$;

select public.review_media((select refused from photos), false);
select is((select payload ->> 'status' from pg_temp.reviewed((select refused from photos)) payload), 'rejected',
  'a refusal by a person is queued for db-events');
select is((select (payload ->> 'secondLook')::boolean from pg_temp.reviewed((select refused from photos)) payload), false,
  'a first decision is not a second look (push only)');
select is((select payload ->> 'userId' from pg_temp.reviewed((select refused from photos)) payload),
  (select ana from ids)::text, 'with the owner');

select public.review_media((select looked_again from photos), false);
select is((select (payload ->> 'secondLook')::boolean from pg_temp.reviewed((select looked_again from photos)) payload),
  true, 'a refusal after a second look asked for says so (push and email)');

select public.review_media((select approved from photos), true);
select is((select payload ->> 'status' from pg_temp.reviewed((select approved from photos)) payload), 'approved',
  'an approval by a person is queued too');

select public.review_media((select refused from photos), false);
select is((select count(*) from pg_temp.reviewed((select refused from photos))), 1::bigint,
  'confirming a refusal again announces nothing');

select is((select count(*) from private.outbox where event = 'media.approved_on_review'
    and payload ->> 'mediaId' = (select approved::text from photos)), 0::bigint,
  'no second-look email for a first approval');

select ok(not has_function_privilege('authenticated', 'public.review_media(uuid, boolean)', 'execute')
    and not has_function_privilege('anon', 'public.review_media(uuid, boolean)', 'execute'),
  'still the team only');

select * from finish();
rollback;
