-- Moderation holds on an account, set by the team (dashboard, Studio or SQL), never by its owner:
--
-- - `review`: the account is being checked. Its owner sees a waiting screen until it's cleared.
-- - `banned`: closed for good. Its email and phone number can't be used to sign up again.
--
-- A held account is frozen like a paused one (20260926000001): hidden from everyone, nothing goes out,
-- chats read-only. The hold forces `paused` on and remembers the owner's own choice, given back when
-- the hold is lifted. The open app hears the change at once (Realtime broadcast `moderation` on
-- `user:<id>`) and reads `profiles.moderation` again when it comes to the front.
--
-- The dashboard calls `public.set_moderation(user, state, note)` with the service role. Editing the
-- column directly (Studio) does the same, without the note.

create type public.moderation_state as enum ('review', 'banned');

-- Readable by the owner (the app shows the screen from it), writable only by the service role: it's
-- not in the column grants of 20260924000002.
alter table public.profiles add column moderation public.moderation_state;

-- The owner's own pause while a hold is on, given back when it's lifted.
create table private.moderation_holds (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  was_paused boolean not null
);

-- Every change, for the dashboard. Goes with the account when it's deleted.
create table private.moderation_log (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  state public.moderation_state,
  note text check (char_length(note) <= 1000),
  created_at timestamptz not null default now()
);

create index moderation_log_user_idx on private.moderation_log (user_id, created_at desc);

-- Email and phone of banned accounts. No foreign key: they outlive the account, so deleting it and
-- signing up again doesn't work. Emails are lowercased, phones kept as digits (like auth.users.phone).
create table private.banned_identities (
  kind text not null check (kind in ('email', 'phone')),
  value text not null check (char_length(value) between 1 and 320),
  user_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (kind, value)
);

create index banned_identities_user_idx on private.banned_identities (user_id);

-- MARK: The hold

-- Before the row changes: a new hold pauses the profile, a lifted one gives the owner's pause back.
-- While held, the owner can't resume.
create function private.moderation_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_was_paused boolean;
begin
  if new.moderation is not distinct from old.moderation then
    if new.moderation is not null and not new.paused then
      perform private.fail('moderated', 'your account is on hold');
    end if;
    return new;
  end if;
  if old.moderation is null then
    insert into private.moderation_holds (user_id, was_paused) values (new.id, old.paused)
      on conflict (user_id) do update set was_paused = excluded.was_paused;
    new.paused := true;
  elsif new.moderation is null then
    delete from private.moderation_holds where user_id = new.id returning was_paused into v_was_paused;
    new.paused := coalesce(v_was_paused, false);
  end if;
  return new;
end;
$$;

create trigger profiles_moderation_guard before update of paused, moderation on public.profiles
  for each row execute function private.moderation_guard();

-- After: logged, identities banned or cleared, chats frozen or reopened, and the open app told.
create function private.on_moderation()
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
      select 'email', lower(trim(u.email)), u.id from auth.users u where u.id = new.id and coalesce(trim(u.email), '') <> ''
      union all
      select 'phone', regexp_replace(u.phone, '\D', '', 'g'), u.id from auth.users u
        where u.id = new.id and regexp_replace(coalesce(u.phone, ''), '\D', '', 'g') <> ''
      on conflict (kind, value) do update set user_id = excluded.user_id;
  elsif old.moderation = 'banned' then
    delete from private.banned_identities where user_id = new.id;
  end if;

  -- `profiles_paused` only fires when the statement itself sets `paused`; the guard set it here.
  if new.paused is distinct from old.paused then
    perform private.emit('profile.paused', jsonb_build_object('userId', new.id, 'paused', new.paused));
  end if;

  perform private.broadcast(new.id, 'moderation', jsonb_build_object('state', new.moderation));
  return null;
end;
$$;

create trigger profiles_moderation after update of moderation on public.profiles
  for each row execute function private.on_moderation();

-- The same guard every action already goes through: a hold answers `moderated` (the app shows its
-- screen), before the pause's own answer.
create or replace function private.require_unpaused(p_user uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_moderation public.moderation_state;
  v_paused boolean;
begin
  select moderation, paused into v_moderation, v_paused from public.profiles where id = p_user;
  if v_moderation is not null then
    perform private.fail('moderated', 'your account is on hold');
  end if;
  if v_paused then
    perform private.fail('paused', 'your profile is paused, resume it first');
  end if;
end;
$$;

-- MARK: No new account for a banned person

-- Sign-up (email, Apple, Google) and email or phone changes. The banned account itself still signs in,
-- to see why.
create function private.refuse_banned_identity()
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
      and ((b.kind = 'email' and b.value = lower(trim(new.email)))
        or (b.kind = 'phone' and b.value = regexp_replace(coalesce(new.phone, ''), '\D', '', 'g')))
  ) then
    perform private.fail('banned', 'this account can no longer be used on drafft');
  end if;
  return new;
end;
$$;

create trigger auth_users_refuse_banned before insert or update of email, phone on auth.users
  for each row execute function private.refuse_banned_identity();

-- MARK: Dashboard

-- Puts a hold on an account (`review`, `banned`) or lifts it (null). Service role only.
create function public.set_moderation(p_user uuid, p_state public.moderation_state, p_note text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform set_config('drafft.moderation_note', coalesce(p_note, ''), true);
  update public.profiles set moderation = p_state where id = p_user;
  if not found then
    perform private.fail('not_found', 'no such account');
  end if;
end;
$$;

revoke execute on function public.set_moderation(uuid, public.moderation_state, text) from public, anon, authenticated;
grant execute on function public.set_moderation(uuid, public.moderation_state, text) to service_role;
