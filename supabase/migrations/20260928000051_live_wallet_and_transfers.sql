-- The wallet stays live in the app, and RevenueCat transfers move premium.
--
-- 1. Every change to a row of public.wallets (purchase, refund, weekly boost, start_boost, super like,
--    undo, premium starting or ending, transfer) broadcasts `wallet` on `user:<id>` with the whole balance
--    (the row without user_id and premium_event_at). An AFTER trigger covers every writer, so
--    credit_weekly_boosts() no longer sends its own.
-- 2. apply_purchase_event() handles TRANSFER: premium_until moves from the `transferred_from` accounts to
--    the `transferred_to` ones (ids that are not drafft accounts are ignored) and the old accounts lose it.
--    Consumables (boosts, super likes) already credited stay put: they were bought once, credited once to
--    the account that bought them and possibly spent; moving them would credit twice or go negative.

create function private.broadcast_wallet()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.broadcast(new.user_id, 'wallet', to_jsonb(new) - 'user_id' - 'premium_event_at');
  return null;
end;
$$;

revoke execute on function private.broadcast_wallet() from public, anon, authenticated;

create trigger wallets_broadcast_insert after insert on public.wallets
  for each row execute function private.broadcast_wallet();
create trigger wallets_broadcast_update after update on public.wallets
  for each row when (old is distinct from new) execute function private.broadcast_wallet();

create or replace function private.credit_weekly_boosts()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_count int := 0;
begin
  for r in
    update public.wallets
      set boosts = boosts + 1,
          weekly_boost_at = weekly_boost_at
            + (floor(extract(epoch from now() - weekly_boost_at) / 604800) + 1) * interval '7 days'
      where weekly_boost_at <= now() and premium_until > now()
      returning user_id
  loop
    -- The balance itself goes out through wallets_broadcast.
    perform private.emit('boost.weekly', jsonb_build_object('userId', r.user_id));
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

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
  v_from uuid[];
  v_to uuid[];
  v_until timestamptz;
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
  -- RevenueCat moved the purchases to another App User ID (restore on a new account, default
  -- "Transfer to new App User ID"): premium follows the subscription. Consumables stay where they are.
  elsif v_type = 'TRANSFER' then
    select coalesce(array_agg(w.user_id), '{}') into v_from from public.wallets w
      where w.user_id::text in (select lower(jsonb_array_elements_text(coalesce(p_event -> 'transferred_from', '[]'))));
    select coalesce(array_agg(w.user_id), '{}') into v_to from public.wallets w
      where w.user_id::text in (select lower(jsonb_array_elements_text(coalesce(p_event -> 'transferred_to', '[]'))))
        and not w.user_id = any (v_from);
    select max(premium_until) into v_until from public.wallets where user_id = any (v_from);
    v_user := v_to[1];
    if cardinality(v_to) = 0 then
      v_effect := 'ignored: no known transferred_to';
    else
      if v_until > now() then
        update public.wallets
          set premium_until = greatest(premium_until, v_until),
              premium_event_at = greatest(premium_event_at, v_event_at)
          where user_id = any (v_to);
      end if;
      update public.wallets set premium_until = null, premium_event_at = greatest(premium_event_at, v_event_at)
        where user_id = any (v_from) and premium_until is not null;
      v_effect := 'transfer: premium_until ' || coalesce(v_until::text, 'none') || ' from '
        || cardinality(v_from) || ' to ' || cardinality(v_to) || ' account(s)';
    end if;
  elsif v_user is null then
    v_effect := 'ignored: unknown app_user_id ' || coalesce(p_event ->> 'app_user_id', 'null');
  elsif v_kind is null then
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
    -- BILLING_ISSUE, SUBSCRIPTION_PAUSED…: no wallet change (the expiration events follow).
    v_effect := 'no change';
  end if;

  insert into public.purchase_events (id, type, user_id, product_id, environment, event_at, effect)
  values (v_id, v_type, v_user, v_product, p_event ->> 'environment', v_event_at, v_effect);
  return v_effect;
end;
$$;

revoke execute on function public.apply_purchase_event(jsonb) from public, anon, authenticated;
grant execute on function public.apply_purchase_event(jsonb) to service_role;
