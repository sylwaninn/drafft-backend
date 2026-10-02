-- Device check on Android: Play Integrity (and its Device recall bits) next to Apple DeviceCheck.
--
-- The account's latest device record now says which service its token belongs to: `ios` (an Apple
-- DeviceCheck token) or `android` (a Play Integrity token, checked by device-check before it is stored). A
-- Play Integrity token can write Device recall for 14 days after the app asked for it, so db-events only
-- sets the bits of an Android device whose token is that recent.
--
-- The two bits mean the same on both platforms: bit0 = an account was closed on this device, bit1 = an
-- account is on hold on it (Device recall's bitFirst and bitSecond).

-- MARK: Table

alter table private.device_checks
  add column platform text not null default 'ios' check (platform in ('ios', 'android'));

-- A Play Integrity token is a few KB (Apple's is about 3 KB base64).
alter table private.device_checks drop constraint device_checks_token_check;
alter table private.device_checks add constraint device_checks_token_check check (char_length(token) between 20 and 16384);

-- MARK: Functions

drop function public.record_device_check(uuid, text, text);

-- device-check (service role): stores the token and says what to do with the device's bits, as before.
-- p_platform is optional for the iPhone builds, which don't send it.
create function public.record_device_check(p_user uuid, p_token text, p_environment text, p_platform text default 'ios')
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_moderation public.moderation_state;
  v_flagged timestamptz;
begin
  select moderation into v_moderation from public.profiles where id = p_user;
  if not found then
    perform private.fail('not_found', 'no such account');
  end if;
  insert into private.device_checks (user_id, token, environment, platform)
    values (p_user, p_token, p_environment, coalesce(p_platform, 'ios'))
    on conflict (user_id) do update
      set token = excluded.token, environment = excluded.environment, platform = excluded.platform, updated_at = now()
    returning flagged_at into v_flagged;
  return case
    when v_moderation = 'banned' then 'ban'
    when v_moderation is not null then 'hold'
    when v_flagged is null then 'check'
    else 'none'
  end;
end;
$$;

drop function public.device_check_token(uuid);

-- db-events: the account's latest token, to set or clear its bits. `updated_at` tells whether a Play
-- Integrity token can still write (14 days).
create function public.device_check_token(p_user uuid)
returns table (token text, environment text, platform text, updated_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select token, environment, platform, updated_at from private.device_checks where user_id = p_user;
$$;

revoke execute on function public.record_device_check(uuid, text, text, text), public.device_check_token(uuid)
  from public, anon, authenticated;
grant execute on function public.record_device_check(uuid, text, text, text), public.device_check_token(uuid)
  to service_role;
