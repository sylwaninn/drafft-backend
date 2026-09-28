-- RevenueCat events only count in the project's store environment (Vault secret purchase_environment).
begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

insert into auth.users (id, email, aud, role, instance_id)
values ('22222222-2222-4222-8222-222222222222', 'env-buyer@test.dev', 'authenticated', 'authenticated',
        '00000000-0000-0000-0000-000000000000');

-- Sets (or, with null, removes) the secret for this transaction only.
create function pg_temp.set_env(p_value text) returns void language plpgsql as $$
begin
  delete from vault.secrets where name = 'purchase_environment';
  if p_value is not null then
    perform vault.create_secret(p_value, 'purchase_environment');
  end if;
end;
$$;

create function pg_temp.ev(p_id text, p_environment text, p_type text default 'NON_RENEWING_PURCHASE',
                           p_user text default '22222222-2222-4222-8222-222222222222')
returns text language sql as $$
  select public.apply_purchase_event(jsonb_strip_nulls(jsonb_build_object(
    'id', p_id, 'type', p_type, 'product_id', 'so.drafft.app.superlike.3', 'app_user_id', p_user,
    'event_timestamp_ms', 1000, 'environment', p_environment)));
$$;

create function pg_temp.super_likes() returns int language sql as $$
  select super_likes from public.wallets where user_id = '22222222-2222-4222-8222-222222222222';
$$;

-- No secret: production.
select pg_temp.set_env(null);
select is(pg_temp.ev('p1', 'SANDBOX'), 'ignored: sandbox event', 'without the secret, a sandbox purchase is ignored');
select is(pg_temp.super_likes(), 0, 'and credits nothing');
select is((select effect || ' ' || environment from public.purchase_events where id = 'p1'),
  'ignored: sandbox event SANDBOX', 'the ignored event is recorded');
select is(pg_temp.ev('p1', 'SANDBOX'), 'duplicate', 'a retried ignored event is recorded once');
select is(pg_temp.ev('p2', 'PRODUCTION'), '+3 superlike', 'without the secret, a production purchase credits');
select is(pg_temp.ev('p3', 'SANDBOX', 'NON_RENEWING_PURCHASE', '$RCAnonymousID:abc'), 'ignored: sandbox event',
  'the environment is checked before the user');
select is(pg_temp.ev('p4', null), 'ignored: unknown event', 'an event without environment is ignored');

-- Explicit production.
select pg_temp.set_env('PRODUCTION');
select is(pg_temp.ev('p5', 'SANDBOX'), 'ignored: sandbox event', 'PRODUCTION ignores sandbox purchases');

-- Staging and local.
select pg_temp.set_env('SANDBOX');
select is(pg_temp.ev('s1', 'SANDBOX'), '+3 superlike', 'SANDBOX credits sandbox purchases');
select is(pg_temp.ev('s2', 'PRODUCTION'), 'ignored: production event', 'SANDBOX ignores production purchases');
select is(pg_temp.ev('s3', 'PRODUCTION', 'TEST'), 'test event', 'dashboard test events are recorded anywhere');

select pg_temp.set_env('staging');
select throws_ok($$ select pg_temp.ev('x1', 'SANDBOX') $$, 'P0001',
  'Vault secret purchase_environment must be PRODUCTION or SANDBOX', 'any other value fails, so RevenueCat retries');

select * from finish();
rollback;
