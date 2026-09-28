-- Purchases only count in the store environment they belong to (FN-02). RevenueCat sends every event with
-- `environment` SANDBOX (TestFlight, App Review, Xcode) or PRODUCTION (App Store). Production TestFlight
-- builds buy in the sandbox and their SDK still syncs to the production RevenueCat project, so without
-- this check sandbox purchases would credit boosts, super likes and premium in the production database.
--
-- The environment a project accepts comes from the Vault secret `purchase_environment`:
--   absent or PRODUCTION  production (the default, nothing to set)
--   SANDBOX               staging (scripts/sync-vault.sh staging) and local (supabase/seed.sql)
-- Any other value fails the call, so RevenueCat retries until it is fixed rather than events being lost.
-- A mismatched event is still recorded once (`ignored: sandbox event` or `ignored: production event`),
-- after the duplicate check, and changes nothing. TEST events from the RevenueCat dashboard stay
-- `test event` in any environment.

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
  v_user uuid;
  v_kind text;
  v_quantity int;
  v_effect text;
  v_environment text := upper(p_event ->> 'environment');
  v_expected text := coalesce(
    (select upper(btrim(decrypted_secret)) from vault.decrypted_secrets where name = 'purchase_environment'), 'PRODUCTION');
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

  if v_expected not in ('PRODUCTION', 'SANDBOX') then
    perform private.fail('invalid_config', 'Vault secret purchase_environment must be PRODUCTION or SANDBOX');
  end if;

  if v_type = 'TEST' then
    v_effect := 'test event';
  -- Another store environment's purchase: recorded, never credited.
  elsif v_environment is distinct from v_expected then
    v_effect := 'ignored: ' || coalesce(lower(v_environment), 'unknown') || ' event';
  elsif v_user is null then
    v_effect := 'ignored: unknown app_user_id ' || coalesce(p_event ->> 'app_user_id', 'null');
  elsif v_kind is null and v_type <> 'TRANSFER' then
    v_effect := 'ignored: unknown product ' || coalesce(v_product, 'null');

  -- Consumable packs: credit on purchase, take back on refund (never below zero).
  elsif v_kind in ('boost', 'superlike') and v_type = 'NON_RENEWING_PURCHASE' then
    if v_kind = 'boost' then
      update public.wallets set boosts = boosts + v_quantity where user_id = v_user;
    else
      update public.wallets set super_likes = super_likes + v_quantity where user_id = v_user;
    end if;
    v_effect := '+' || v_quantity || ' ' || v_kind;
  elsif v_kind in ('boost', 'superlike') and v_type = 'CANCELLATION' then
    if v_kind = 'boost' then
      update public.wallets set boosts = greatest(boosts - v_quantity, 0) where user_id = v_user;
    else
      update public.wallets set super_likes = greatest(super_likes - v_quantity, 0) where user_id = v_user;
    end if;
    v_effect := '-' || v_quantity || ' ' || v_kind || ' (refund)';

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
