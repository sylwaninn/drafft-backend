-- Support limits: signed in per account; signed out per address (hour and day) and a signed-out cap of
-- its own, which signed-in traffic and deleted accounts don't eat into.
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

create temp table ids as select pg_temp.person('ana@test.dev') as ana;

-- Signed out, per address.
select public.create_support_request(null, 'victim@else.dev', 'en', 't', 'm') from generate_series(1, 3);
select throws_ok($$select public.create_support_request(null, ' Victim@Else.dev ', 'en', 't', 'm')$$,
  'P0001', 'too many messages, try again later', 'signed out: 3 an hour per address, whatever its case');
select is((select bool_and(signed_out) from private.support_requests where lower(email) = 'victim@else.dev'), true,
  'stored as signed out');

update private.support_requests set created_at = now() - interval '2 hours' where lower(email) = 'victim@else.dev';
select public.create_support_request(null, 'victim@else.dev', 'en', 't', 'm') from generate_series(1, 2);
select throws_ok($$select public.create_support_request(null, 'victim@else.dev', 'en', 't', 'm')$$,
  'P0001', 'too many messages, try again later', 'signed out: 5 a day per address');
select lives_ok($$select public.create_support_request(null, 'other@else.dev', 'en', 't', 'm')$$,
  'another address is not held back');

-- Signed in: per account, and apart from the signed-out counts.
select lives_ok(format($$select public.create_support_request(%L, 'victim@else.dev', 'fr', 't', 'm')$$,
    (select ana from ids)), 'signed-in traffic has its own limits');
select is((select signed_out from private.support_requests where user_id = (select ana from ids)), false,
  'stored as signed in');
select public.create_support_request((select ana from ids), 'ana@test.dev', 'fr', 't', 'm') from generate_series(1, 4);
select throws_ok(format($$select public.create_support_request(%L, 'ana@test.dev', 'fr', 't', 'm')$$, (select ana from ids)),
  'P0001', 'too many messages, try again later', 'signed in: 5 an hour per account');

-- The signed-out cap: 200 an hour, signed-in rows not counted.
insert into private.support_requests (reference, user_id, email, topic, message, signed_out)
  select 'DR-T' || lpad(i::text, 5, '0'), null, 'bulk' || i || '@else.dev', 't', 'm', true from generate_series(1, 200) i;
select throws_ok($$select public.create_support_request(null, 'fresh@else.dev', 'en', 't', 'm')$$,
  'P0001', 'too many messages, try again later', 'signed out: 200 an hour in all');
select lives_ok(format($$select public.create_support_request(%L, 'ana2@test.dev', 'en', 't', 'm')$$,
    pg_temp.person('ana2@test.dev')), 'signed in still gets through');

select * from finish();
rollback;
