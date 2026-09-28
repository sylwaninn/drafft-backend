-- Every wallet change is broadcast on user:<id>; RevenueCat TRANSFER moves premium between accounts.
begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

insert into auth.users (id, email, aud, role, instance_id) values
  ('33333333-3333-4333-8333-333333333331', 'old-account@test.dev', 'authenticated', 'authenticated',
   '00000000-0000-0000-0000-000000000000'),
  ('33333333-3333-4333-8333-333333333332', 'new-account@test.dev', 'authenticated', 'authenticated',
   '00000000-0000-0000-0000-000000000000');

create function pg_temp.sent(p_user text) returns bigint language sql as $$
  select count(*) from realtime.messages where topic = 'user:' || p_user and event = 'wallet';
$$;
-- The message sent after the snapshot in `seen` (every message of a transaction shares inserted_at, and
-- ids are random uuids, so order can't tell them apart).
create temp table seen (id uuid);
create function pg_temp.last(p_user text) returns jsonb language sql as $$
  select payload from realtime.messages where topic = 'user:' || p_user and event = 'wallet'
    and id not in (select id from seen);
$$;
create function pg_temp.w(p_user text) returns public.wallets language sql as $$
  select * from public.wallets where user_id = p_user::uuid;
$$;

-- Broadcast on every change, with the whole balance.
select lives_ok($$ select pg_temp.sent('33333333-3333-4333-8333-333333333331') $$, 'realtime.messages is readable');
create temp table n0 as select pg_temp.sent('33333333-3333-4333-8333-333333333331') as n;
insert into seen select id from realtime.messages;
update public.wallets set super_likes = 4 where user_id = '33333333-3333-4333-8333-333333333331';
select is(pg_temp.sent('33333333-3333-4333-8333-333333333331'), (select n + 1 from n0), 'a wallet change is broadcast');
select is((pg_temp.last('33333333-3333-4333-8333-333333333331') ->> 'super_likes')::int, 4,
  'with the new balance');
select ok(pg_temp.last('33333333-3333-4333-8333-333333333331') ? 'boosts'
  and pg_temp.last('33333333-3333-4333-8333-333333333331') ? 'premium_until'
  and not pg_temp.last('33333333-3333-4333-8333-333333333331') ? 'user_id', 'the whole balance, without user_id');
update public.wallets set super_likes = 4 where user_id = '33333333-3333-4333-8333-333333333331';
select is(pg_temp.sent('33333333-3333-4333-8333-333333333331'), (select n + 1 from n0), 'a no-op update sends nothing');

-- Weekly boost: one broadcast, from the trigger.
update public.wallets set premium_until = now() + interval '30 days'
  where user_id = '33333333-3333-4333-8333-333333333331';
update public.wallets set weekly_boost_at = now() - interval '1 minute'
  where user_id = '33333333-3333-4333-8333-333333333331';
create temp table n1 as select pg_temp.sent('33333333-3333-4333-8333-333333333331') as n;
select private.credit_weekly_boosts();
select is(pg_temp.sent('33333333-3333-4333-8333-333333333331'), (select n + 1 from n1), 'the weekly boost is broadcast once');
select ok(exists (select 1 from realtime.messages where topic = 'user:33333333-3333-4333-8333-333333333331'
  and event = 'wallet' and (payload ->> 'boosts')::int = (pg_temp.w('33333333-3333-4333-8333-333333333331')).boosts),
  'with the new boosts balance');

-- Transfer.
delete from vault.secrets where name = 'purchase_environment';
create function pg_temp.transfer(p_id text, p_from jsonb, p_to jsonb) returns text language sql as $$
  select public.apply_purchase_event(jsonb_build_object('id', p_id, 'type', 'TRANSFER', 'environment', 'PRODUCTION',
    'event_timestamp_ms', 2000, 'app_user_id', p_to ->> 0, 'transferred_from', p_from, 'transferred_to', p_to));
$$;
create temp table until0 as select (pg_temp.w('33333333-3333-4333-8333-333333333331')).premium_until as t;

select matches(pg_temp.transfer('t1', '["33333333-3333-4333-8333-333333333331"]', '["33333333-3333-4333-8333-333333333332"]'),
  '^transfer: premium_until .+ from 1 to 1 account\(s\)$', 'a transfer between two accounts applies');
select is((pg_temp.w('33333333-3333-4333-8333-333333333332')).premium_until, (select t from until0),
  'the new account gets premium');
select is((pg_temp.w('33333333-3333-4333-8333-333333333331')).premium_until, null, 'the old account loses it');
select is((pg_temp.w('33333333-3333-4333-8333-333333333331')).super_likes, 4, 'consumables stay put');
select is(pg_temp.transfer('t1', '["33333333-3333-4333-8333-333333333331"]', '["33333333-3333-4333-8333-333333333332"]'),
  'duplicate', 'a retried transfer is applied once');
select is(pg_temp.transfer('t2', '["$RCAnonymousID:abc"]', '["$RCAnonymousID:def"]'),
  'ignored: no known transferred_to', 'ids that are not accounts are ignored');
select is((select user_id::text || ' ' || type from public.purchase_events where id = 't1'),
  '33333333-3333-4333-8333-333333333332 TRANSFER', 'the transfer is recorded');

select * from finish();
rollback;
