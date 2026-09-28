-- Consumables are credited once per store transaction, whether the webhook or purchase-sync sees it first.
begin;
create extension if not exists pgtap with schema extensions;
select plan(30);

insert into auth.users (id, email, aud, role, instance_id)
values ('44444444-4444-4444-8444-444444444441', 'sync-buyer@test.dev', 'authenticated', 'authenticated',
        '00000000-0000-0000-0000-000000000000');

delete from vault.secrets where name = 'purchase_environment';

create function pg_temp.ev(p_id text, p_txn text, p_type text default 'NON_RENEWING_PURCHASE',
                           p_env text default 'PRODUCTION')
returns text language sql as $$
  select public.apply_purchase_event(jsonb_strip_nulls(jsonb_build_object(
    'id', p_id, 'type', p_type, 'product_id', 'so.drafft.app.superlike.3',
    'app_user_id', '44444444-4444-4444-8444-444444444441', 'event_timestamp_ms', 1000,
    'environment', p_env, 'transaction_id', p_txn)));
$$;
create function pg_temp.sync(p_purchases jsonb, p_premium text default null) returns jsonb language sql as $$
  select public.apply_purchase_sync('44444444-4444-4444-8444-444444444441',
    jsonb_build_object('purchases', p_purchases, 'premium_expires_at', p_premium));
$$;
create function pg_temp.p(p_txn text, p_status text default 'owned', p_env text default 'production',
                          p_product text default 'so.drafft.app.superlike.3')
returns jsonb language sql as $$
  select jsonb_build_object('transaction_id', p_txn, 'product_id', p_product, 'status', p_status, 'environment', p_env);
$$;
create function pg_temp.w() returns public.wallets language sql as $$
  select * from public.wallets where user_id = '44444444-4444-4444-8444-444444444441';
$$;

-- Webhook first, then sync: one credit.
select is(pg_temp.ev('e1', 't1'), '+3 superlike', 'the webhook credits a transaction');
select is((pg_temp.sync(jsonb_build_array(pg_temp.p('t1'))) -> 'wallet' ->> 'super_likes')::int, 3,
  'sync of the same transaction credits nothing more, and returns the wallet');
select is(pg_temp.ev('e1', 't1'), 'duplicate', 'a retried event stays a duplicate');
select is(pg_temp.ev('e1b', 't1'), 'already credited: t1', 'another event of the same transaction credits nothing');

-- Sync first, then webhook: one credit.
select is((pg_temp.sync(jsonb_build_array(pg_temp.p('t2'))) -> 'wallet' ->> 'super_likes')::int, 6, 'sync credits a new transaction');
select is(pg_temp.ev('e2', 't2'), 'already credited: t2', 'the webhook then credits nothing');
select is((pg_temp.sync(jsonb_build_array(pg_temp.p('t2'))) -> 'wallet' ->> 'super_likes')::int, 6, 'a second sync credits nothing');

-- Refunds: once, whichever path.
select is(pg_temp.ev('e3', 't2', 'CANCELLATION'), '-3 superlike (refund)', 'the webhook takes a refunded pack back');
select is((pg_temp.sync(jsonb_build_array(pg_temp.p('t2', 'refunded'))) -> 'wallet' ->> 'super_likes')::int, 3,
  'sync of the refund takes nothing more');
select is((pg_temp.sync(jsonb_build_array(pg_temp.p('t1', 'refunded'))) -> 'wallet' ->> 'super_likes')::int, 0, 'sync takes a refund back');
select is(pg_temp.ev('e4', 't1', 'CANCELLATION'), 'refund recorded: t1', 'the webhook refund then takes nothing');
select is(pg_temp.ev('e5', 't9', 'CANCELLATION'), 'refund recorded: t9', 'a refund before its purchase is recorded');
select is((pg_temp.sync(jsonb_build_array(pg_temp.p('t9'))) -> 'wallet' ->> 'super_likes')::int, 0, 'and never credited afterwards');

-- Environment.
select is((pg_temp.sync(jsonb_build_array(pg_temp.p('t3', 'owned', 'sandbox'))) -> 'wallet' ->> 'super_likes')::int, 0,
  'a sandbox purchase is not credited in production');
select vault.create_secret('SANDBOX', 'purchase_environment');
select is((pg_temp.sync(jsonb_build_array(pg_temp.p('t3', 'owned', 'sandbox'))) -> 'wallet' ->> 'super_likes')::int, 3,
  'a sandbox purchase is credited where the secret says SANDBOX');
delete from vault.secrets where name = 'purchase_environment';
select is((pg_temp.sync(jsonb_build_array(pg_temp.p('t4', 'owned', 'production', 'so.drafft.app.tempo.monthly')))
  -> 'wallet' ->> 'super_likes')::int, 3, 'a subscription product is never a consumable');

-- Premium: copied, never added.
select is((pg_temp.sync('[]', '2030-01-01T00:00:00Z') -> 'wallet' ->> 'premium_until')::timestamptz, '2030-01-01T00:00:00Z'::timestamptz,
  'premium_until is copied from the entitlement');
select is((pg_temp.sync('[]', '2030-01-01T00:00:00Z') -> 'wallet' ->> 'premium_until')::timestamptz, '2030-01-01T00:00:00Z'::timestamptz,
  'a second sync does not extend it');
select is((pg_temp.sync('[]', null) -> 'wallet' ->> 'premium_until')::timestamptz, '2030-01-01T00:00:00Z'::timestamptz,
  'without an active entitlement, sync leaves premium to the webhook');

-- Transaction status for the app.
create function pg_temp.status(p_purchases jsonb, p_txn text) returns jsonb language sql as $$
  select public.apply_purchase_sync('44444444-4444-4444-8444-444444444441',
    jsonb_build_object('purchases', p_purchases), p_txn) -> 'transaction';
$$;
select is(pg_temp.sync('[]') -> 'transaction', 'null'::jsonb, 'no transaction asked, no status');
select is(pg_temp.status(jsonb_build_array(pg_temp.p('t5')), 't5'), '{"id": "t5", "credited": true}'::jsonb,
  'a consumable credited by this sync is reported credited');
select is(pg_temp.status('[]', 't5'), '{"id": "t5", "credited": true}'::jsonb,
  'and stays credited on the next sync');
select is(pg_temp.status('[]', 't1'), '{"id": "t1", "credited": false}'::jsonb, 'a refunded one is not credited');
select is(pg_temp.status('[]', 'unknown'), '{"id": "unknown", "credited": false}'::jsonb,
  'a transaction RevenueCat does not know yet is not credited');
select is(pg_temp.status(jsonb_build_array(pg_temp.p('t6', 'owned', 'production', 'so.drafft.app.tempo.monthly')), 't6'),
  '{"id": "t6", "credited": true}'::jsonb, 'an owned subscription with premium active is credited');
update public.wallets set premium_until = now() - interval '1 day' where user_id = '44444444-4444-4444-8444-444444444441';
select is(pg_temp.status(jsonb_build_array(pg_temp.p('t6', 'owned', 'production', 'so.drafft.app.tempo.monthly')), 't6'),
  '{"id": "t6", "credited": false}'::jsonb, 'not once premium has ended');

-- TRANSFER still moves premium (20260928000051).
insert into auth.users (id, email, aud, role, instance_id)
values ('44444444-4444-4444-8444-444444444442', 'sync-restorer@test.dev', 'authenticated', 'authenticated',
        '00000000-0000-0000-0000-000000000000');
update public.wallets set premium_until = now() + interval '30 days' where user_id = '44444444-4444-4444-8444-444444444441';
select matches(public.apply_purchase_event(jsonb_build_object('id', 'tr1', 'type', 'TRANSFER', 'environment', 'PRODUCTION',
    'event_timestamp_ms', 2000, 'app_user_id', '44444444-4444-4444-8444-444444444442',
    'transferred_from', jsonb_build_array('44444444-4444-4444-8444-444444444441'),
    'transferred_to', jsonb_build_array('44444444-4444-4444-8444-444444444442'))),
  '^transfer: premium_until .+ from 1 to 1 account\(s\)$', 'a transfer moves premium to the new account');

-- Limits.
select lives_ok($$ select public.purchase_sync_begin('44444444-4444-4444-8444-444444444441') $$, 'a first call is allowed');
select throws_ok($$ select public.purchase_sync_begin('44444444-4444-4444-8444-444444444441') $$, 'P0001',
  'too many purchase syncs, try again later', 'a second call within 5 seconds is refused');
update private.purchase_sync_calls set called_at = now() - interval '10 minutes';
insert into private.purchase_sync_calls (user_id, called_at)
  select '44444444-4444-4444-8444-444444444441', now() - interval '20 minutes' from generate_series(1, 29);
select throws_ok($$ select public.purchase_sync_begin('44444444-4444-4444-8444-444444444441') $$, 'P0001',
  'too many purchase syncs, try again later', 'the 31st call in an hour is refused');

select * from finish();
rollback;
