-- Pushes to Android phones, through Firebase Cloud Messaging (FCM HTTP v1).
--
-- A push token now says which service it belongs to: `ios` (an APNs device token, 64 hex digits) or
-- `android` (an FCM registration token, longer and with a colon). The Android app sends its platform;
-- an iPhone build that doesn't is recognised by its token's shape, as are the tokens already stored.
-- db-events sends each device through its own service (`_shared/push.ts`).
--
-- FCM gets its own circuit breaker, and every event that pushes lists it next to APNs.

-- MARK: Tokens

alter table public.push_tokens
  add column platform text not null default 'ios' check (platform in ('ios', 'android'));

update public.push_tokens set platform = 'android' where token !~ '^[0-9a-fA-F]{64}$';

-- FCM tokens are about 160 characters today, with no documented maximum.
alter table public.push_tokens drop constraint push_tokens_token_check;
alter table public.push_tokens add constraint push_tokens_token_check check (char_length(token) <= 4096);

drop function public.register_push_token(text, text);

-- A device token moves to whoever signed in last on that device. p_platform is optional for the
-- iPhone builds that don't send it yet.
create function public.register_push_token(p_token text, p_environment text, p_platform text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_platform text := coalesce(
    p_platform,
    case when p_token ~ '^[0-9a-fA-F]{64}$' then 'ios' else 'android' end
  );
begin
  perform private.require_not_held((select auth.uid()));
  insert into public.push_tokens (token, user_id, environment, platform)
  values (p_token, (select auth.uid()), p_environment, v_platform)
  on conflict (token) do update
    set user_id = excluded.user_id, environment = excluded.environment, platform = excluded.platform,
        updated_at = now();
end;
$$;

revoke execute on function public.register_push_token(text, text, text) from public, anon;
grant execute on function public.register_push_token(text, text, text) to authenticated;

-- MARK: Provider

alter table private.provider_circuits drop constraint provider_circuits_provider_check;
alter table private.provider_circuits add constraint provider_circuits_provider_check
  check (provider in ('stream', 'apns', 'fcm', 'resend', 'twilio', 'r2'));
insert into private.provider_circuits (provider) values ('fcm');

alter table private.outbox_policies drop constraint outbox_policies_providers_check;
alter table private.outbox_policies add constraint outbox_policies_providers_check
  check (providers <@ array['stream', 'apns', 'fcm', 'resend', 'twilio', 'r2']);
update private.outbox_policies set providers = providers || '{fcm}'
  where 'apns' = any (providers) and not 'fcm' = any (providers);
