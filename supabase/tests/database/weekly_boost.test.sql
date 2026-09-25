-- drafft tempo's weekly boost: first one on subscribing, one per due week while premium, none after.
begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

insert into auth.users (id, email, aud, role, instance_id)
values ('22222222-2222-4222-8222-222222222222', 'tempo@test.dev', 'authenticated', 'authenticated',
        '00000000-0000-0000-0000-000000000000');

create function pg_temp.wallet() returns public.wallets language sql as $$
  select * from public.wallets where user_id = '22222222-2222-4222-8222-222222222222';
$$;

create function pg_temp.subscribe(p_id text, p_type text, p_expires interval) returns text language sql as $$
  select public.apply_purchase_event(jsonb_build_object(
    'id', p_id, 'type', p_type, 'product_id', 'so.drafft.app.tempo.monthly',
    'app_user_id', '22222222-2222-4222-8222-222222222222',
    'event_timestamp_ms', (extract(epoch from clock_timestamp()) * 1000)::bigint,
    'expiration_at_ms', (extract(epoch from now() + p_expires) * 1000)::bigint, 'environment', 'SANDBOX'));
$$;

create function pg_temp.pushes() returns bigint language sql as $$
  select count(*) from private.outbox
  where event = 'boost.weekly' and payload ->> 'userId' = '22222222-2222-4222-8222-222222222222';
$$;

-- Subscribing: the first boost now, the next in a week.
select pg_temp.subscribe('w1', 'INITIAL_PURCHASE', interval '30 days');
select is((pg_temp.wallet()).boosts, 1, 'subscribing credits the first weekly boost');
select is((pg_temp.wallet()).weekly_boost_at, now() + interval '7 days', 'the next one is a week later');

-- A renewal changes neither the balance nor the date.
select pg_temp.subscribe('w2', 'RENEWAL', interval '60 days');
select is((pg_temp.wallet()).boosts, 1, 'a renewal adds no boost');

-- Not due yet: nothing happens.
select is(private.credit_weekly_boosts(), 0, 'nothing is credited before the date');

-- Due (and a run missed for two more weeks): one boost, one push, next date still ahead.
update public.wallets set weekly_boost_at = now() - interval '15 days'
  where user_id = '22222222-2222-4222-8222-222222222222';
select is(private.credit_weekly_boosts(), 1, 'a due boost is credited');
select is((pg_temp.wallet()).boosts, 2, 'one boost, not a backlog');
select is((pg_temp.wallet()).weekly_boost_at, now() + interval '6 days', 'the next date is the first one ahead');
select is(pg_temp.pushes(), 1::bigint, 'boost.weekly is emitted for the push');

-- Premium ends: the date is cleared and nothing more is credited.
select pg_temp.subscribe('w3', 'EXPIRATION', interval '-1 second');
select is((pg_temp.wallet()).weekly_boost_at, null, 'expiring clears the date');
select is(private.credit_weekly_boosts(), 0, 'no boost without premium');

-- The app writes the push settings on its own profile.
set local role authenticated;
set local request.jwt.claims = '{"sub": "22222222-2222-4222-8222-222222222222", "role": "authenticated"}';
update public.profiles set language = 'fr', notify_weekly_boost = false
  where id = '22222222-2222-4222-8222-222222222222';
reset role;
select is((select language || ' ' || notify_weekly_boost::text from public.profiles
           where id = '22222222-2222-4222-8222-222222222222'), 'fr false', 'language and setting are saved');

select * from finish();
rollback;
