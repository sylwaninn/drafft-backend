-- RevenueCat events: consumables, subscription state, idempotency, ordering, unknown users.
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

insert into auth.users (id, email, aud, role, instance_id)
values ('11111111-1111-4111-8111-111111111111', 'buyer@test.dev', 'authenticated', 'authenticated',
        '00000000-0000-0000-0000-000000000000');

create function pg_temp.ev(p_id text, p_type text, p_product text, p_at bigint, p_expires bigint default null,
                           p_user text default '11111111-1111-4111-8111-111111111111')
returns text language sql as $$
  select public.apply_purchase_event(jsonb_build_object(
    'id', p_id, 'type', p_type, 'product_id', p_product, 'app_user_id', p_user,
    'event_timestamp_ms', p_at, 'expiration_at_ms', p_expires, 'environment', 'SANDBOX'));
$$;

create function pg_temp.wallet() returns public.wallets language sql as $$
  select * from public.wallets where user_id = '11111111-1111-4111-8111-111111111111';
$$;

select is(pg_temp.ev('e1', 'NON_RENEWING_PURCHASE', 'so.drafft.app.superlike.15', 1000), '+15 superlike',
  'a super like pack credits the wallet');
select is(pg_temp.ev('e1', 'NON_RENEWING_PURCHASE', 'so.drafft.app.superlike.15', 1000), 'duplicate',
  'the same event twice credits once');
select is((pg_temp.wallet()).super_likes, 15, 'balance is 15');

select pg_temp.ev('e2', 'NON_RENEWING_PURCHASE', 'so.drafft.app.boost.5', 2000);
select pg_temp.ev('e3', 'CANCELLATION', 'so.drafft.app.boost.5', 3000);
select is((pg_temp.wallet()).boosts, 0, 'a refunded boost pack is taken back');

-- Subscription: purchase, then renewal, then a late-arriving older event.
select pg_temp.ev('s1', 'INITIAL_PURCHASE', 'so.drafft.app.tempo.monthly',
  extract(epoch from now())::bigint * 1000, extract(epoch from now() + interval '30 days')::bigint * 1000);
select ok(private.is_premium('11111111-1111-4111-8111-111111111111'), 'subscribing makes the account premium');
select pg_temp.ev('s2', 'RENEWAL', 'so.drafft.app.tempo.monthly',
  extract(epoch from now() + interval '1 minute')::bigint * 1000, extract(epoch from now() + interval '60 days')::bigint * 1000);
select is(pg_temp.ev('s0', 'EXPIRATION', 'so.drafft.app.tempo.monthly', 1000, 2000), 'ignored: older than current state',
  'an older event cannot undo a newer one');
select ok(private.is_premium('11111111-1111-4111-8111-111111111111'), 'still premium after the stale event');

-- Refund: RevenueCat sends a cancellation with the expiration set to the refund time.
select pg_temp.ev('s3', 'CANCELLATION', 'so.drafft.app.tempo.monthly',
  extract(epoch from now() + interval '2 minutes')::bigint * 1000, extract(epoch from now() - interval '1 second')::bigint * 1000);
select ok(not private.is_premium('11111111-1111-4111-8111-111111111111'), 'a refund ends premium');

select alike(pg_temp.ev('u1', 'NON_RENEWING_PURCHASE', 'so.drafft.app.boost.1', 4000, null, '$RCAnonymousID:abc'),
  'ignored: unknown app_user_id%', 'purchases before login are recorded and ignored');

select * from finish();
rollback;
