-- Purchases credited once per store transaction, from the webhook or from purchase-sync.
--
-- 1. private.purchase_credits: one row per App Store transaction of a consumable (boosts, super likes),
--    keyed by the store transaction id (`transaction_id` of the webhook, `store_purchase_identifier` of
--    RevenueCat's API). Whoever sees a transaction first, the webhook or purchase-sync, credits it; the
--    other finds the row and does nothing. A refund takes the pack back once, and a refund seen before the
--    purchase records the transaction so it is never credited afterwards.
-- 2. apply_purchase_event() keeps its idempotence per event id and now credits and refunds consumables
--    through that table. Subscriptions are unchanged: premium_until is copied, never added.
-- 3. purchase_sync_begin() (limits: 1 call per 5 s, 30 per hour and account) and apply_purchase_sync()
--    back the purchase-sync Edge Function, which reads the caller's RevenueCat state right after a purchase
--    so the credit doesn't wait for the webhook. premium_until is copied from the drafft_tempo entitlement.
-- 4. private.purchase_environment(): the store environment of the project (Vault `purchase_environment`),
--    shared by both paths.

create table private.purchase_credits (
  transaction_id text primary key,
  user_id uuid references public.profiles (id) on delete set null,
  product_id text not null,
  kind text not null check (kind in ('boost', 'superlike')),
  quantity int not null check (quantity > 0),
  -- Who saw the transaction first: webhook or sync.
  source text not null check (source in ('webhook', 'sync')),
  -- Null when the refund arrived before the purchase (nothing was credited).
  credited_at timestamptz,
  refunded_at timestamptz,
  created_at timestamptz not null default now()
);

create index purchase_credits_user_idx on private.purchase_credits (user_id);

create table private.purchase_sync_calls (
  user_id uuid not null references public.profiles (id) on delete cascade,
  called_at timestamptz not null default now()
);

create index purchase_sync_calls_user_idx on private.purchase_sync_calls (user_id, called_at desc);

create function private.purchase_environment()
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_expected text := coalesce(
    (select upper(btrim(decrypted_secret)) from vault.decrypted_secrets where name = 'purchase_environment'), 'PRODUCTION');
begin
  if v_expected not in ('PRODUCTION', 'SANDBOX') then
    perform private.fail('invalid_config', 'Vault secret purchase_environment must be PRODUCTION or SANDBOX');
  end if;
  return v_expected;
end;
$$;

-- Credits a consumable pack once per store transaction. Returns whether it credited.
create function private.credit_consumable(p_user uuid, p_transaction text, p_product text, p_source text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kind text;
  v_quantity int;
begin
  select kind, quantity into v_kind, v_quantity from public.store_products
    where product_id = p_product and kind in ('boost', 'superlike');
  if v_kind is null then
    return false;
  end if;
  if p_transaction is not null then
    insert into private.purchase_credits (transaction_id, user_id, product_id, kind, quantity, source, credited_at)
      values (p_transaction, p_user, p_product, v_kind, v_quantity, p_source, now())
      on conflict (transaction_id) do nothing;
    if not found then
      return false;
    end if;
  end if;
  if v_kind = 'boost' then
    update public.wallets set boosts = boosts + v_quantity where user_id = p_user;
  else
    update public.wallets set super_likes = super_likes + v_quantity where user_id = p_user;
  end if;
  return true;
end;
$$;

-- Takes a refunded pack back once (never below zero). A refund of a transaction never credited is
-- recorded, so neither path credits it later. Returns whether it took anything back.
create function private.refund_consumable(p_user uuid, p_transaction text, p_product text, p_source text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row private.purchase_credits;
  v_kind text;
  v_quantity int;
begin
  -- No transaction id: take the pack back as before (the event id keeps it idempotent).
  if p_transaction is null then
    select p_transaction, p_user, p_product, kind, quantity, p_source, now()
      into v_row.transaction_id, v_row.user_id, v_row.product_id, v_row.kind, v_row.quantity, v_row.source,
           v_row.credited_at
      from public.store_products where product_id = p_product and kind in ('boost', 'superlike');
    if v_row.kind is null then
      return false;
    end if;
  else
    update private.purchase_credits set refunded_at = now()
      where transaction_id = p_transaction and refunded_at is null
      returning * into v_row;
  end if;
  if v_row.kind is null then
    select kind, quantity into v_kind, v_quantity from public.store_products
      where product_id = p_product and kind in ('boost', 'superlike');
    if v_kind is not null then
      insert into private.purchase_credits (transaction_id, user_id, product_id, kind, quantity, source, refunded_at)
        values (p_transaction, p_user, p_product, v_kind, v_quantity, p_source, now())
        on conflict (transaction_id) do nothing;
    end if;
    return false;
  end if;
  if v_row.credited_at is null then
    return false;
  end if;
  if v_row.kind = 'boost' then
    update public.wallets set boosts = greatest(boosts - v_row.quantity, 0) where user_id = v_row.user_id;
  else
    update public.wallets set super_likes = greatest(super_likes - v_row.quantity, 0) where user_id = v_row.user_id;
  end if;
  return true;
end;
$$;

revoke execute on function private.purchase_environment() from public, anon, authenticated;
revoke execute on function private.credit_consumable(uuid, text, text, text) from public, anon, authenticated;
revoke execute on function private.refund_consumable(uuid, text, text, text) from public, anon, authenticated;

create or replace function public.apply_purchase_event(p_event jsonb)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id text := p_event ->> 'id';
  v_type text := p_event ->> 'type';
  v_product text := p_event ->> 'product_id';
  v_event_at timestamptz := to_timestamp(coalesce((p_event ->> 'event_timestamp_ms')::bigint, 0) / 1000.0);
  v_expires timestamptz := to_timestamp((p_event ->> 'expiration_at_ms')::bigint / 1000.0);
  -- The store transaction: the key of every consumable credit, shared with purchase-sync.
  -- Without one (never sent by RevenueCat for a store purchase), the event id alone keeps it idempotent.
  v_transaction text := nullif(p_event ->> 'transaction_id', '');
  v_user uuid;
  v_kind text;
  v_quantity int;
  v_effect text;
  v_environment text := upper(p_event ->> 'environment');
  v_expected text;
begin
  if v_id is null or v_type is null then
    perform private.fail('invalid_event', 'event id and type are required');
  end if;
  if exists (select 1 from public.purchase_events where id = v_id) then
    return 'duplicate';
  end if;

  begin
    v_user := (p_event ->> 'app_user_id')::uuid;
  exception when invalid_text_representation then
    v_user := null;
  end;
  if v_user is not null and not exists (select 1 from public.wallets where user_id = v_user) then
    v_user := null;
  end if;
  select kind, quantity into v_kind, v_quantity from public.store_products where product_id = v_product;

  v_expected := private.purchase_environment();

  if v_type = 'TEST' then
    v_effect := 'test event';
  -- Another store environment's purchase: recorded, never credited.
  elsif v_environment is distinct from v_expected then
    v_effect := 'ignored: ' || coalesce(lower(v_environment), 'unknown') || ' event';
  elsif v_user is null then
    v_effect := 'ignored: unknown app_user_id ' || coalesce(p_event ->> 'app_user_id', 'null');
  elsif v_kind is null and v_type <> 'TRANSFER' then
    v_effect := 'ignored: unknown product ' || coalesce(v_product, 'null');

  -- Consumable packs: credit on purchase, take back on refund, once per store transaction.
  elsif v_kind in ('boost', 'superlike') and v_type = 'NON_RENEWING_PURCHASE' then
    v_effect := case when private.credit_consumable(v_user, v_transaction, v_product, 'webhook')
      then '+' || v_quantity || ' ' || v_kind
      else 'already credited: ' || v_transaction end;
  elsif v_kind in ('boost', 'superlike') and v_type = 'CANCELLATION' then
    v_effect := case when private.refund_consumable(v_user, v_transaction, v_product, 'webhook')
      then '-' || v_quantity || ' ' || v_kind || ' (refund)'
      else 'refund recorded: ' || v_transaction end;

  -- Subscription: RevenueCat's expiration is the current truth (a refund sets it in the past).
  elsif v_kind = 'subscription' and v_type in ('INITIAL_PURCHASE', 'RENEWAL', 'UNCANCELLATION', 'PRODUCT_CHANGE',
      'SUBSCRIPTION_EXTENDED', 'TEMPORARY_ENTITLEMENT_GRANT', 'CANCELLATION', 'EXPIRATION') then
    if v_expires is null then
      v_effect := 'ignored: no expiration_at_ms';
    else
      update public.wallets
        set premium_until = v_expires, premium_event_at = v_event_at
        where user_id = v_user and (premium_event_at is null or premium_event_at <= v_event_at);
      v_effect := case when found then 'premium_until ' || v_expires else 'ignored: older than current state' end;
    end if;
  else
    -- BILLING_ISSUE, SUBSCRIPTION_PAUSED, TRANSFER…: no wallet change (the expiration events follow).
    v_effect := 'no change';
  end if;

  insert into public.purchase_events (id, type, user_id, product_id, environment, event_at, effect)
  values (v_id, v_type, v_user, v_product, p_event ->> 'environment', v_event_at, v_effect);
  return v_effect;
end;
$$;

revoke execute on function public.apply_purchase_event(jsonb) from public, anon, authenticated;
grant execute on function public.apply_purchase_event(jsonb) to service_role;

-- Starts a purchase-sync call: at most 1 per 5 seconds and 30 per hour and account (hint too_many_requests,
-- a refused call doesn't count). Returns the store environment the caller's purchases must come from.
create function public.purchase_sync_begin(p_user uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_environment text := private.purchase_environment();
begin
  -- Serialises concurrent calls of one account.
  perform 1 from public.wallets where user_id = p_user for update;
  if not found then
    perform private.fail('not_found', 'no wallet for this account');
  end if;
  delete from private.purchase_sync_calls where user_id = p_user and called_at < now() - interval '1 hour';
  if exists (select 1 from private.purchase_sync_calls where user_id = p_user and called_at > now() - interval '5 seconds')
     or (select count(*) from private.purchase_sync_calls where user_id = p_user) >= 30 then
    perform private.fail('too_many_requests', 'too many purchase syncs, try again later');
  end if;
  insert into private.purchase_sync_calls (user_id) values (p_user);
  return v_environment;
end;
$$;

-- Applies the caller's RevenueCat state, read by purchase-sync:
--   { "purchases": [{ "transaction_id", "product_id" (store id), "status": "owned" | "refunded", "environment" }],
--     "premium_expires_at": timestamptz or null (active drafft_tempo entitlement in this environment) }
-- Consumables are credited or refunded once per transaction (shared with the webhook); premium_until is
-- copied from the entitlement when it is active. Returns the wallet.
create function public.apply_purchase_sync(p_user uuid, p_state jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_expected text := private.purchase_environment();
  v_purchase jsonb;
  v_premium timestamptz := (p_state ->> 'premium_expires_at')::timestamptz;
  v_wallet public.wallets;
begin
  if not exists (select 1 from public.wallets where user_id = p_user) then
    perform private.fail('not_found', 'no wallet for this account');
  end if;

  for v_purchase in select * from jsonb_array_elements(coalesce(p_state -> 'purchases', '[]'))
  loop
    continue when upper(v_purchase ->> 'environment') is distinct from v_expected
      or coalesce(v_purchase ->> 'transaction_id', '') = '';
    if v_purchase ->> 'status' = 'owned' then
      perform private.credit_consumable(p_user, v_purchase ->> 'transaction_id', v_purchase ->> 'product_id', 'sync');
    elsif v_purchase ->> 'status' = 'refunded' then
      perform private.refund_consumable(p_user, v_purchase ->> 'transaction_id', v_purchase ->> 'product_id', 'sync');
    end if;
  end loop;

  if v_premium is not null then
    update public.wallets
      set premium_until = v_premium, premium_event_at = greatest(premium_event_at, now())
      where user_id = p_user and premium_until is distinct from v_premium;
  end if;

  select * into v_wallet from public.wallets where user_id = p_user;
  return to_jsonb(v_wallet) - 'user_id' - 'premium_event_at';
end;
$$;

revoke execute on function public.purchase_sync_begin(uuid) from public, anon, authenticated;
revoke execute on function public.apply_purchase_sync(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.purchase_sync_begin(uuid) to service_role;
grant execute on function public.apply_purchase_sync(uuid, jsonb) to service_role;
