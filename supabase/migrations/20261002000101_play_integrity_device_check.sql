-- Device check on Android: Play Integrity (and its Device recall bits) next to Apple DeviceCheck.
--
-- The account's latest device record now says which service its token belongs to: `ios` (an Apple
-- DeviceCheck token) or `android` (a Play Integrity token, checked by device-check before it is stored). A
-- Play Integrity token can write Device recall for 14 days (counted from when device-check stored it), so
-- db-events sets or clears the bits of an Android device only while its token is that recent. A change it
-- can't apply (a token too old, Google down) waits in `pending_bit0` / `pending_bit1`, and device-check
-- applies it with the next verified token: a ban lifted while the person was away must not leave their own
-- bit on the phone, or they would be sent to review on it.
--
-- The bits mean the same on both platforms: bit0 = an account was closed on this device, bit1 = an
-- account is on hold on it (Device recall's bitFirst and bitSecond).
--
-- Each Android check costs a decode call to Google, whose default quota (10,000 a day) is shared by both
-- projects: device_check_begin limits an account to 20 checks an hour and tells device-check when it can skip
-- the decode.

-- MARK: Table

alter table private.device_checks
  add column platform text not null default 'ios' check (platform in ('ios', 'android')),
  add column pending_bit0 boolean,
  add column pending_bit1 boolean;

-- A Play Integrity token is a few KB; device-check still caps an Apple token at 8 KB.
alter table private.device_checks drop constraint device_checks_token_check;
alter table private.device_checks add constraint device_checks_token_check check (char_length(token) between 20 and 16384);

-- device-check's calls, to limit them (an hour, trimmed at the account's next call).
create table private.device_check_calls (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  called_at timestamptz not null default now()
);

create index device_check_calls_user_idx on private.device_check_calls (user_id, called_at desc);

-- MARK: Functions

drop function public.record_device_check(uuid, text, text);

-- device-check (service role): stores the token and says what to do with the device's bits.
--   'ban'    closed: set bit0;
--   'hold'   on hold: set bit1;
--   'check'  in good standing and never flagged: read the bits, then device_flagged() if one is set;
--   'none'   nothing.
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

-- db-events: the account's latest token, to set or clear its bits. `platform` and `updated_at` tell whether
-- a Play Integrity token can still write (14 days).
create function public.device_check_token(p_user uuid)
returns table (token text, environment text, platform text, updated_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select token, environment, platform, updated_at from private.device_checks where user_id = p_user;
$$;

-- device-check, Android, before it asks Google anything: counts the call (at most 20 an hour and account,
-- hint too_many_requests) and says where the account stands:
--   standing     'banned', 'held' (review or selfie) or 'ok';
--   verified_at  when its latest Android token was verified, null when its last device record isn't Android;
--   has_pending  a bit change waits for the next verified token.
create function public.device_check_begin(p_user uuid)
returns table (standing text, verified_at timestamptz, has_pending boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_moderation public.moderation_state;
begin
  -- Serialises concurrent calls of one account.
  select moderation into v_moderation from public.profiles where id = p_user for update;
  if not found then
    perform private.fail('not_found', 'no such account');
  end if;
  delete from private.device_check_calls where user_id = p_user and called_at < now() - interval '1 hour';
  if (select count(*) from private.device_check_calls where user_id = p_user) >= 20 then
    perform private.fail('too_many_requests', 'too many device checks, try again later');
  end if;
  insert into private.device_check_calls (user_id) values (p_user);
  return query select
    case when v_moderation = 'banned' then 'banned' when v_moderation is not null then 'held' else 'ok' end,
    (select c.updated_at from private.device_checks c where c.user_id = p_user and c.platform = 'android'),
    coalesce((select c.pending_bit0 is not null or c.pending_bit1 is not null
      from private.device_checks c where c.user_id = p_user), false);
end;
$$;

-- db-events: a bit change it couldn't write (null: leave that bit alone). A later change to the same bit
-- replaces the earlier one. Nothing when the account has no device record.
create function public.device_check_set_pending(p_user uuid, p_bit0 boolean, p_bit1 boolean)
returns void
language sql
security definer
set search_path = ''
as $$
  update private.device_checks
    set pending_bit0 = coalesce(p_bit0, pending_bit0), pending_bit1 = coalesce(p_bit1, pending_bit1)
    where user_id = p_user;
$$;

-- device-check: takes the waiting bit change (null: nothing for that bit) and clears it. When the write that
-- follows fails, device-check puts it back with device_check_set_pending.
create function public.device_check_take_pending(p_user uuid)
returns table (bit0 boolean, bit1 boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bit0 boolean;
  v_bit1 boolean;
begin
  select pending_bit0, pending_bit1 into v_bit0, v_bit1 from private.device_checks where user_id = p_user for update;
  update private.device_checks set pending_bit0 = null, pending_bit1 = null where user_id = p_user;
  return query select v_bit0, v_bit1;
end;
$$;

revoke execute on function public.record_device_check(uuid, text, text, text), public.device_check_token(uuid),
  public.device_check_begin(uuid), public.device_check_set_pending(uuid, boolean, boolean),
  public.device_check_take_pending(uuid) from public, anon, authenticated;
grant execute on function public.record_device_check(uuid, text, text, text), public.device_check_token(uuid),
  public.device_check_begin(uuid), public.device_check_set_pending(uuid, boolean, boolean),
  public.device_check_take_pending(uuid) to service_role;
