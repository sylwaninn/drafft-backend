-- A hold follows the person, not the account (20260926000003, 20260927000001, 20260927000003).
--
-- Every hold marks the account's identities: its normalised email, its phone, its Apple or Google
-- sign-in. The marks outlive the account, so deleting it and signing up again doesn't escape anything:
--   banned          no new account with that identity (as before);
--   selfie, review  a new account with that identity starts with the same hold, the strictest one still
--                   pending (a selfie asked, then sent, is still owed by a new account: the old selfie
--                   went with the deleted account).
-- Lifting the hold clears its marks. The device follows the same rule through DeviceCheck: bit0 = an
-- account was closed on this iPhone (review), bit1 = an account is on hold on it (selfie).
--
-- Identities are stored as HMAC-SHA256 digests, never in clear: a key generated in each database's Vault
-- by this migration (identity_hash_key), never leaving it. The same person gives the same digest in one
-- environment and a different one elsewhere. Losing the key forgets every mark, so it's never rotated.

select vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'identity_hash_key',
    'HMAC key for private.identity_marks. Never rotate or delete: every mark would be forgotten.')
  where not exists (select 1 from vault.secrets where name = 'identity_hash_key');

create function private.identity_hash(p_kind text, p_value text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select encode(extensions.hmac(p_kind || ':' || p_value,
      (select decrypted_secret from vault.decrypted_secrets where name = 'identity_hash_key'), 'sha256'), 'hex')
  where p_value is not null and p_value <> '';
$$;

-- Every identity of an account, digested: email and phone normalised (20260927000001), and each Apple or
-- Google sign-in by its provider's own stable id.
create function private.account_identities(p_user uuid)
returns table (kind text, hash text)
language sql
stable
security definer
set search_path = ''
as $$
  select 'email', private.identity_hash('email', private.normalize_email(u.email)) from auth.users u
    where u.id = p_user and private.normalize_email(u.email) is not null
  union
  select 'phone', private.identity_hash('phone', private.normalize_phone(u.phone)) from auth.users u
    where u.id = p_user and private.normalize_phone(u.phone) is not null
  union
  select 'oauth', private.identity_hash('oauth', i.provider || ':' || i.provider_id) from auth.identities i
    where i.user_id = p_user and i.provider not in ('email', 'phone');
$$;

create table private.identity_marks (
  kind text not null check (kind in ('email', 'phone', 'oauth')),
  hash text not null check (char_length(hash) = 64),
  state public.moderation_state not null,
  -- The account that left the mark (deleted since, often): no foreign key.
  user_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (kind, hash)
);

create index identity_marks_user_idx on private.identity_marks (user_id);

-- Holds from before this migration, digested.
insert into private.identity_marks (kind, hash, state, user_id)
  select i.kind, i.hash, p.moderation, p.id
  from public.profiles p cross join lateral private.account_identities(p.id) i
  where p.moderation is not null
  on conflict (kind, hash) do nothing;
-- Bans of accounts deleted since: their clear values are digested the same way.
insert into private.identity_marks (kind, hash, state, user_id)
  select b.kind, private.identity_hash(b.kind, b.value), 'banned', b.user_id from private.banned_identities b
  on conflict (kind, hash) do update set state = 'banned';

-- migration-guard: allow destructive drop - replaced by private.identity_marks (digests, not clear values), never on main
drop table private.banned_identities;

-- The strictest first: banned, then a selfie owed, then a review.
create function private.hold_rank(p_state public.moderation_state)
returns int
language sql
immutable
set search_path = ''
as $$
  select case p_state when 'banned' then 3 when 'selfie' then 2 when 'review' then 1 else 0 end;
$$;

-- MARK: Holds and their marks

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

  if new.moderation is null then
    delete from private.identity_marks where user_id = new.id;
  else
    -- A ban replaces any mark; a hold never lowers one (a selfie owed stays owed once it's sent).
    insert into private.identity_marks (kind, hash, state, user_id)
      select kind, hash, new.moderation, new.id from private.account_identities(new.id)
      on conflict (kind, hash) do update
        set state = case when private.hold_rank(excluded.state) >= private.hold_rank(identity_marks.state)
                           or identity_marks.user_id <> excluded.user_id
                      then excluded.state else identity_marks.state end,
            user_id = excluded.user_id;
    -- Marks taken over from a deleted account (inherit_hold) follow too: a ban closes them all.
    update private.identity_marks set state = new.moderation
      where user_id = new.id
        and (new.moderation = 'banned' or private.hold_rank(state) < private.hold_rank(new.moderation));
  end if;

  -- The iPhone's DeviceCheck bits, and the "you're back" email when a hold is lifted (db-events).
  perform private.emit('account.moderation',
    jsonb_build_object('userId', new.id, 'state', new.moderation, 'previous', old.moderation));

  -- `profiles_paused` only fires when the statement itself sets `paused`; the guard set it here.
  if new.paused is distinct from old.paused then
    perform private.emit('profile.paused', jsonb_build_object('userId', new.id, 'paused', new.paused));
  end if;

  perform private.broadcast(new.id, 'moderation', jsonb_build_object('state', new.moderation));
  return null;
end;
$$;

-- MARK: Sign-up and identity changes

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
    select 1 from private.identity_marks m
    where m.state = 'banned' and m.user_id <> new.id
      and ((m.kind = 'email' and m.hash = private.identity_hash('email', private.normalize_email(new.email)))
        or (m.kind = 'phone' and m.hash = private.identity_hash('phone', private.normalize_phone(new.phone))))
  ) then
    perform private.fail('banned', 'this account can no longer be used on drafft');
  end if;
  return new;
end;
$$;

-- Apple and Google sign-ins: refused when banned.
create function private.refuse_banned_oauth()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.provider not in ('email', 'phone') and exists (
    select 1 from private.identity_marks m
    where m.state = 'banned' and m.kind = 'oauth' and m.user_id <> new.user_id
      and m.hash = private.identity_hash('oauth', new.provider || ':' || new.provider_id)
  ) then
    perform private.fail('banned', 'this account can no longer be used on drafft');
  end if;
  return new;
end;
$$;

create trigger auth_identities_refuse_banned before insert on auth.identities
  for each row execute function private.refuse_banned_oauth();

-- An account that shares an identity with one on hold starts with that hold. Called when the account is
-- created, when its email or phone changes (the phone is verified after sign-up), and on a new sign-in.
create function private.inherit_hold(p_user uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_state public.moderation_state;
  v_kind text;
  v_source uuid;
begin
  select m.state, m.kind, m.user_id into v_state, v_kind, v_source
  from private.account_identities(p_user) i
  join private.identity_marks m on m.kind = i.kind and m.hash = i.hash
  where m.user_id <> p_user and m.state in ('review', 'selfie')
  order by private.hold_rank(m.state) desc
  limit 1;
  if v_state is null or not exists (select 1 from public.profiles where id = p_user and moderation is null) then
    return;
  end if;
  -- The source account is gone: this one takes over all its marks (its other email or phone too), so
  -- lifting this hold frees them all and a ban closes them all.
  update private.identity_marks set user_id = p_user
    where user_id = v_source and not exists (select 1 from auth.users where id = v_source);
  perform set_config('drafft.moderation_note', 'carried over: same ' || v_kind || ' as an account on hold', true);
  update public.profiles set moderation = v_state where id = p_user;
end;
$$;

create function private.on_identity_changed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_table_name = 'identities' then
    perform private.inherit_hold(new.user_id);
  elsif tg_op = 'INSERT' or new.email is distinct from old.email or new.phone is distinct from old.phone then
    perform private.inherit_hold(new.id);
  end if;
  return null;
end;
$$;

-- After on_auth_user_created (triggers fire by name): the profile exists by then.
create trigger on_auth_user_identity after insert or update of email, phone on auth.users
  for each row execute function private.on_identity_changed();
create trigger on_auth_identity_added after insert on auth.identities
  for each row execute function private.on_identity_changed();

-- MARK: DeviceCheck

-- device-check (service role): stores the token and says what to do with the iPhone's bits.
--   'ban'    closed: set bit0;
--   'hold'   on hold: set bit1;
--   'check'  in good standing and never flagged: read the bits, then device_flagged() if one is set;
--   'none'   nothing.
create or replace function public.record_device_check(p_user uuid, p_token text, p_environment text)
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
  return case
    when v_moderation = 'banned' then 'ban'
    when v_moderation is not null then 'hold'
    when v_flagged is null then 'check'
    else 'none'
  end;
end;
$$;

-- migration-guard: allow destructive drop - a function (not a table), replaced by the two-bit version below
drop function public.device_flagged(uuid);

-- The iPhone's bits were set by another account: an account on hold there (bit1) means a selfie, one
-- closed there (bit0) a review. Once per account: the team's decision then stands (second-hand iPhones).
create function public.device_flagged(p_user uuid, p_closed boolean, p_held boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not (p_closed or p_held) then
    return;
  end if;
  update private.device_checks set flagged_at = now() where user_id = p_user and flagged_at is null;
  if found and exists (select 1 from public.profiles where id = p_user and moderation is null) then
    perform public.set_moderation(p_user, case when p_held then 'selfie' else 'review' end::public.moderation_state,
      case when p_held then 'device of an account on hold' else 'device used by a closed account' end);
  end if;
end;
$$;

revoke execute on function public.device_flagged(uuid, boolean, boolean) from public, anon, authenticated;
grant execute on function public.device_flagged(uuid, boolean, boolean) to service_role;
