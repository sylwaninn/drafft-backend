-- Purchases, credited from RevenueCat webhooks (revenuecat-webhook function, service role only).
--
-- The app logs in to RevenueCat with the Supabase user id, so `app_user_id` is a profile id.
-- Every event is recorded once (idempotent on its id); subscription state only moves forward in time,
-- so a late or retried event can't undo a newer one.

create table public.store_products (
  product_id text primary key,
  kind text not null check (kind in ('subscription', 'boost', 'superlike')),
  quantity int not null default 1 check (quantity > 0)
);

-- Mirrors the app's catalogue (PaywallView plans, ExtrasSheet packs). App Store Connect and RevenueCat
-- must use these exact product ids.
insert into public.store_products (product_id, kind, quantity) values
  ('so.drafft.app.tempo.monthly', 'subscription', 1),
  ('so.drafft.app.tempo.sixmonths', 'subscription', 1),
  ('so.drafft.app.tempo.yearly', 'subscription', 1),
  ('so.drafft.app.boost.1', 'boost', 1),
  ('so.drafft.app.boost.5', 'boost', 5),
  ('so.drafft.app.boost.10', 'boost', 10),
  ('so.drafft.app.superlike.3', 'superlike', 3),
  ('so.drafft.app.superlike.15', 'superlike', 15),
  ('so.drafft.app.superlike.30', 'superlike', 30);

create table public.purchase_events (
  id text primary key,
  type text not null,
  user_id uuid references public.profiles (id) on delete set null,
  product_id text,
  environment text,
  event_at timestamptz not null,
  received_at timestamptz not null default now(),
  -- What this event changed, for support: "+5 boost", "premium_until 2026-10-24", "ignored: ..."
  effect text not null
);

create index purchase_events_user_idx on public.purchase_events (user_id, event_at desc);

alter table public.wallets add column premium_event_at timestamptz;

alter table public.store_products enable row level security;
alter table public.purchase_events enable row level security;
-- The app reads the catalogue (quantities per product); events stay server-side.
create policy store_products_read on public.store_products for select to authenticated using (true);
grant select on public.store_products to authenticated;

-- Applies one RevenueCat event. Returns what it did. Unknown users or products are recorded and
-- ignored (never an error: RevenueCat would retry forever).
create function public.apply_purchase_event(p_event jsonb)
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

  if v_type = 'TEST' then
    v_effect := 'test event';
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
grant all on public.store_products, public.purchase_events to service_role;
