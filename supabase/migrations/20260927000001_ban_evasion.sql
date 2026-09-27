-- Harder to come back after a ban (20260926000003):
--
-- - Emails are compared normalised: lowercase, no `+tag`, no dots for Gmail, Apple's me.com and mac.com
--   as icloud.com. `Jo.Doe+2@googlemail.com` is `jodoe@gmail.com`.
-- - Phones as digits only (auth.users.phone's own format). Virtual and VoIP numbers never get a code
--   (auth-sms, Twilio Lookup).
-- - The device: Apple DeviceCheck keeps two bits per iPhone for drafft, which survive reinstalling the
--   app and a new account. bit0 = an account was closed on this iPhone. The app sends a fresh DeviceCheck
--   token at each launch (device-check function); a ban sets bit0 through it (db-events,
--   `account.moderation`), and a new account on a flagged iPhone goes to `review`, once, for a person to
--   decide: a second-hand iPhone keeps its bits.

create function private.normalize_email(p_email text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_email text := lower(trim(p_email));
  v_at int;
  v_local text;
  v_domain text;
begin
  v_at := length(v_email) - position('@' in reverse(v_email)) + 1;
  if v_email is null or v_email = '' or position('@' in v_email) = 0 then
    return nullif(v_email, '');
  end if;
  v_local := split_part(left(v_email, v_at - 1), '+', 1);
  v_domain := substr(v_email, v_at + 1);
  if v_local = '' then
    return v_email;
  end if;
  if v_domain in ('gmail.com', 'googlemail.com') then
    v_local := replace(v_local, '.', '');
    v_domain := 'gmail.com';
  elsif v_domain in ('me.com', 'mac.com') then
    v_domain := 'icloud.com';
  end if;
  return v_local || '@' || v_domain;
end;
$$;

create function private.normalize_phone(p_phone text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '');
$$;

-- Emails banned before this migration, normalised the same way.
insert into private.banned_identities (kind, value, user_id, created_at)
  select 'email', private.normalize_email(value), user_id, created_at
  from private.banned_identities where kind = 'email'
  on conflict (kind, value) do nothing;
delete from private.banned_identities where kind = 'email' and value <> private.normalize_email(value);

create or replace function private.refuse_banned_identity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.email is not distinct from old.email and new.phone is not distinct from old.phone then
    return new;
  end if;
  if exists (
    select 1 from private.banned_identities b
    where b.user_id <> new.id
      and ((b.kind = 'email' and b.value = private.normalize_email(new.email))
        or (b.kind = 'phone' and b.value = private.normalize_phone(new.phone)))
  ) then
    perform private.fail('banned', 'this account can no longer be used on drafft');
  end if;
  return new;
end;
$$;

-- MARK: DeviceCheck

-- The latest DeviceCheck token of each account (tokens are opaque and single-device; only Apple can tell
-- which iPhone). `flagged_at`: this account was already sent to review for its device, never again.
create table private.device_checks (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  token text not null check (char_length(token) between 20 and 8192),
  environment text not null check (environment in ('development', 'production')),
  flagged_at timestamptz,
  updated_at timestamptz not null default now()
);

create or replace function private.on_moderation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.moderation is not distinct from old.moderation then
    return null;
  end if;

  insert into private.moderation_log (user_id, state, note)
    values (new.id, new.moderation, nullif(current_setting('drafft.moderation_note', true), ''));

  if new.moderation = 'banned' then
    insert into private.banned_identities (kind, value, user_id)
      select 'email', private.normalize_email(u.email), u.id from auth.users u
        where u.id = new.id and private.normalize_email(u.email) is not null
      union all
      select 'phone', private.normalize_phone(u.phone), u.id from auth.users u
        where u.id = new.id and private.normalize_phone(u.phone) is not null
      on conflict (kind, value) do update set user_id = excluded.user_id;
  elsif old.moderation = 'banned' then
    delete from private.banned_identities where user_id = new.id;
  end if;

  -- The iPhone's DeviceCheck bit follows a ban (db-events).
  if new.moderation = 'banned' or old.moderation = 'banned' then
    perform private.emit('account.moderation',
      jsonb_build_object('userId', new.id, 'state', new.moderation, 'previous', old.moderation));
  end if;

  -- `profiles_paused` only fires when the statement itself sets `paused`; the guard set it here.
  if new.paused is distinct from old.paused then
    perform private.emit('profile.paused', jsonb_build_object('userId', new.id, 'paused', new.paused));
  end if;

  perform private.broadcast(new.id, 'moderation', jsonb_build_object('state', new.moderation));
  return null;
end;
$$;

-- device-check (service role): stores the token and says what to do with the device's bits.
--   'ban'    the account is closed: set bit0 on this iPhone;
--   'check'  read the bits, and call device_flagged() if bit0 is set;
--   'none'   nothing (held for review, or already flagged once).
create function public.record_device_check(p_user uuid, p_token text, p_environment text)
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
  insert into private.device_checks (user_id, token, environment) values (p_user, p_token, p_environment)
    on conflict (user_id) do update set token = excluded.token, environment = excluded.environment, updated_at = now()
    returning flagged_at into v_flagged;
  if v_moderation = 'banned' then
    return 'ban';
  end if;
  if v_moderation is null and v_flagged is null then
    return 'check';
  end if;
  return 'none';
end;
$$;

-- bit0 was set on this account's iPhone: a closed account used it. Review, once.
create function public.device_flagged(p_user uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update private.device_checks set flagged_at = now() where user_id = p_user and flagged_at is null;
  if found and exists (select 1 from public.profiles where id = p_user and moderation is null) then
    perform public.set_moderation(p_user, 'review', 'device used by a closed account');
  end if;
end;
$$;

-- db-events: the account's latest token, to set or clear bit0.
create function public.device_check_token(p_user uuid)
returns table (token text, environment text)
language sql
stable
security definer
set search_path = ''
as $$
  select token, environment from private.device_checks where user_id = p_user;
$$;

revoke execute on function public.record_device_check(uuid, text, text), public.device_flagged(uuid),
  public.device_check_token(uuid) from public, anon, authenticated;
grant execute on function public.record_device_check(uuid, text, text), public.device_flagged(uuid),
  public.device_check_token(uuid) to service_role;
