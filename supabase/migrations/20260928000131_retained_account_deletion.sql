-- Deleting an account under an open report, a hold or a ban keeps it, for members' safety (decisions 2.2,
-- 4.12 and 5.3).
--
-- delete-account asks public.retain_deleted_account first. The account is kept (a soft delete) when it is:
--   ban     banned (profiles.moderation = 'banned');
--   hold    on hold now (review, selfie: profiles.moderation);
--   report  reported, the report still open (public.reports, handled_at null).
-- A hold lifted or a report closed stays in the history (and in the record's refs when the account is kept
-- for another reason), but no longer keeps the account on its own (decision 5.3): a member cleared by the
-- team is not treated as reported any more.
-- Anything else is erased completely, as before (delete-account deletes the Auth user, every table cascades),
-- except the conversations whose other member is banned or on hold at that moment: their messages stay, for
-- the team (decision 5.4, public.deleted_account_chats).
--
-- A kept account:
--   - disappears for everyone: paused for good (Discover, Likes, swipes, boosts already skip paused
--     profiles), its matches ended (both apps drop the chat; db-events freezes the Stream channel), its
--     upcoming sessions cancelled, and its card left out of get_cards and blocked_users;
--   - can't sign in again: the Auth user is banned for 100 years (what GoTrue's own ban writes), its
--     sessions and refresh tokens revoked, its push tokens deleted; db-events bans it in Stream and
--     revokes its Stream tokens (`account.soft_deleted`);
--   - keeps everything else (profile, media, prompts, settings, reports, holds, notes, devices, IPs), read
--     only by sophros. Media objects stay in R2: they go private with the media work (group E);
--   - has a record of why (private.account_deletions): the basis, the reports and holds behind it, the date,
--     and the legal basis, members' safety.
--
-- Signing up again with the same email, phone or Apple/Google sign-in:
--   - banned: refused, by the identity marks the ban left (20260927000004), as before;
--   - otherwise possible. The Auth user's email and phone move to a placeholder and its Apple/Google
--     identities are removed (all copied into the record first), so the address is free. The new account
--     is linked to the old one (private.account_links) and sophros shows it under related accounts. A hold
--     still pending carries over through the identity marks, as before.

-- MARK: Records

alter table public.profiles add column deleted_at timestamptz;

create table private.account_deletions (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  deleted_at timestamptz not null default now(),
  basis text not null check (basis in ('ban', 'hold', 'report')),
  -- What the basis rests on: {"moderation": state, "reports": [ids], "holds": [moderation_log ids]}.
  refs jsonb not null default '{}',
  legal_basis text not null default 'member_safety' check (legal_basis in ('member_safety')),
  -- The sign-in identities the Auth user had, in clear, before they were freed.
  identities jsonb not null default '{}'
);

-- Digests of those identities (private.identity_hash), to link a later account signing up with them.
create table private.deleted_identities (
  kind text not null check (kind in ('email', 'phone', 'oauth')),
  hash text not null check (char_length(hash) = 64),
  user_id uuid not null references private.account_deletions (user_id) on delete cascade,
  primary key (kind, hash, user_id)
);

create index deleted_identities_user_idx on private.deleted_identities (user_id);

create table private.account_links (
  user_id uuid not null references public.profiles (id) on delete cascade,
  deleted_user_id uuid not null references public.profiles (id) on delete cascade,
  via text not null check (via in ('email', 'phone', 'oauth')),
  created_at timestamptz not null default now(),
  primary key (user_id, deleted_user_id, via)
);

create index account_links_deleted_idx on private.account_links (deleted_user_id);

-- MARK: Deleting

-- Why an account must be kept, or null when it can be erased: a ban or a hold in force, or a report still
-- open. `refs` also lists the account's closed reports and past holds, as history for the team.
create function private.retention_basis(p_user uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with facts as (
    select p.moderation,
      exists (select 1 from public.reports r where r.reported = p.id and r.handled_at is null) as open_report,
      coalesce((select jsonb_agg(r.id order by r.created_at) from public.reports r where r.reported = p.id), '[]') as reports,
      coalesce((select jsonb_agg(l.id order by l.created_at) from private.moderation_log l
        where l.user_id = p.id and l.state is not null), '[]') as holds
    from public.profiles p where p.id = p_user
  )
  select jsonb_build_object(
      'basis', case when moderation = 'banned' then 'ban'
                    when moderation is not null then 'hold'
                    else 'report' end,
      'refs', jsonb_build_object('moderation', moderation, 'reports', reports, 'holds', holds))
  from facts
  where moderation is not null or open_report;
$$;

-- delete-account (service role), before erasing anything. Keeps the account and answers
-- {"retained": true, "basis": …} when it is banned, held or under an open report, else {"retained": false}
-- and changes nothing.
-- Idempotent: an account already kept answers retained again.
create function public.retain_deleted_account(p_user uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_why jsonb;
  v_identities jsonb;
begin
  -- A report or a hold arriving meanwhile waits for this decision.
  perform 1 from public.profiles where id = p_user for update;
  if not found then
    return jsonb_build_object('retained', false);
  end if;
  if exists (select 1 from private.account_deletions where user_id = p_user) then
    return jsonb_build_object('retained', true,
      'basis', (select basis from private.account_deletions where user_id = p_user));
  end if;
  v_why := private.retention_basis(p_user);
  if v_why is null then
    return jsonb_build_object('retained', false);
  end if;

  select jsonb_build_object('email', u.email, 'phone', nullif(u.phone, ''),
      'oauth', (select coalesce(jsonb_agg(jsonb_build_object('provider', i.provider, 'providerId', i.provider_id,
          'email', i.email, 'createdAt', i.created_at, 'lastSignInAt', i.last_sign_in_at)), '[]')
        from auth.identities i where i.user_id = u.id and i.provider not in ('email', 'phone')))
    into v_identities
  from auth.users u where u.id = p_user;

  insert into private.account_deletions (user_id, basis, refs, identities)
    values (p_user, v_why ->> 'basis', v_why -> 'refs', coalesce(v_identities, '{}'));
  insert into private.deleted_identities (kind, hash, user_id)
    select kind, hash, p_user from private.account_identities(p_user)
    on conflict do nothing;

  -- Out of sight: sessions first (the other person gets the neutral push, not this account), then the
  -- matches (both apps drop the chat, db-events freezes the channel), then the profile itself.
  perform set_config('drafft.session_actor', p_user::text, true);
  perform private.cancel_upcoming_sessions(null, p_user, p_user, false);
  perform set_config('drafft.session_actor', '', true);
  update public.matches set ended_at = now(), ended_by = p_user
    where p_user in (user_a, user_b) and ended_at is null;
  update public.profiles set deleted_at = now(), paused = true where id = p_user;

  -- No way back in, and nothing sent to the old phone.
  delete from public.push_tokens where user_id = p_user;
  delete from auth.sessions where user_id = p_user;
  delete from auth.identities where user_id = p_user and provider not in ('email', 'phone');
  update auth.users set
      email = p_user::text || '@deleted.drafft.invalid', phone = null,
      email_change = '', phone_change = '', banned_until = now() + interval '100 years'
    where id = p_user;

  perform private.emit('account.soft_deleted', jsonb_build_object('userId', p_user));
  return jsonb_build_object('retained', true, 'basis', v_why ->> 'basis');
end;
$$;

-- delete-account (service role), for an account being erased: which of its conversations keep their
-- messages (decision 5.4). A conversation whose other member is banned or on hold right now is kept, for the
-- team; every other one is erased with the account, as before.
-- {"keep": [{"match": id, "other": user id}], "erase": [match ids]}.
create function public.deleted_account_chats(p_user uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'keep', coalesce(jsonb_agg(jsonb_build_object('match', c.id, 'other', c.other) order by c.id)
      filter (where c.held), '[]'),
    'erase', coalesce(jsonb_agg(c.id order by c.id) filter (where not c.held), '[]'))
  from (
    select m.id, o.id as other, o.moderation is not null as held
    from public.matches m
    join public.profiles o on o.id = case when m.user_a = p_user then m.user_b else m.user_a end
    where p_user in (m.user_a, m.user_b)
  ) c;
$$;

-- A kept account stays paused whatever happens to its hold: lifting one gives back the owner's own pause
-- (private.moderation_guard), which must not bring a deleted profile back. Fires after that guard (by name).
create function private.soft_deleted_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.deleted_at is not null then
    new.paused := true;
  end if;
  return new;
end;
$$;

create trigger profiles_soft_deleted_guard before update of paused, moderation, deleted_at on public.profiles
  for each row execute function private.soft_deleted_guard();

-- MARK: Signing up again

-- A new account signing up with an identity of a kept one is linked to it, for sophros. After
-- on_auth_user_created (triggers fire by name): the profile exists by then.
create function private.link_deleted_account()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid;
begin
  if tg_table_name = 'identities' then
    v_user := new.user_id;
  else
    v_user := new.id;
  end if;
  insert into private.account_links (user_id, deleted_user_id, via)
    select v_user, d.user_id, d.kind
    from private.account_identities(v_user) a
    join private.deleted_identities d on d.kind = a.kind and d.hash = a.hash
    where d.user_id <> v_user and exists (select 1 from public.profiles where id = v_user)
    on conflict do nothing;
  return null;
end;
$$;

create trigger on_auth_user_link_deleted after insert or update of email, phone on auth.users
  for each row execute function private.link_deleted_account();
create trigger on_auth_identity_link_deleted after insert on auth.identities
  for each row execute function private.link_deleted_account();

-- MARK: Out of sight

-- Cards by id: never a kept account's.
create or replace function public.get_cards(p_ids uuid[], p_known jsonb default '{}')
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select c.card || jsonb_build_object('age', private.age_of(p.birthdate), 'cardVersion', c.version)
  from unnest(p_ids[1:100]) as i(id)
  join public.profiles p on p.id = i.id
  join public.profile_cards c on c.user_id = i.id
  where c.version > coalesce((p_known ->> i.id::text)::bigint, 0)
    and p.deleted_at is null
    and not private.blocked_between((select auth.uid()), i.id)
    and (
      exists (select 1 from public.swipes s where s.swiper = (select auth.uid()) and s.target = i.id)
      or exists (select 1 from public.swipes s where s.swiper = i.id and s.target = (select auth.uid()) and s.action <> 'pass')
      or exists (select 1 from public.matches m
                 where m.user_a = least((select auth.uid()), i.id) and m.user_b = greatest((select auth.uid()), i.id)));
$$;

-- Blocked people: a kept account leaves the list, like an erased one does.
create or replace function public.blocked_users()
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
      'id', b.blocked,
      'name', c.card ->> 'name',
      'photo', c.card -> 'media' -> 0,
      'blockedAt', b.created_at)
  from public.blocks b
  join public.profile_cards c on c.user_id = b.blocked
  join public.profiles p on p.id = b.blocked
  where b.blocker = (select auth.uid()) and p.deleted_at is null
  order by b.created_at desc;
$$;

create trigger staff_live_deleted_accounts after update of deleted_at on public.profiles
  for each statement execute function private.staff_queue_changed('accounts');

revoke all on function private.retention_basis(uuid), public.retain_deleted_account(uuid),
  public.deleted_account_chats(uuid), private.soft_deleted_guard(), private.link_deleted_account()
  from public, anon, authenticated;
grant execute on function public.retain_deleted_account(uuid), public.deleted_account_chats(uuid) to service_role;
