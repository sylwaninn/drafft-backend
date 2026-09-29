-- What is kept after its use goes on the privacy policy's schedule ("How long we keep it"). A daily job,
-- private.purge_expired() (pg_cron `privacy-purge`), deletes:
--
--   public.reports                     1 year after it was handled; an open report is never purged
--   private.moderation_log             1 year, 3 years about a banned account; the entry behind a hold still
--                                      in force stays as long as the hold
--   private.staff_notes                1 year, 3 years about a banned account
--   public.media_flags                 1 year after the review (or the flag, never reviewed), 3 years about a
--                                      banned account
--   private.account_links              1 year, 3 years when either account is banned
--   private.admin_audit                1 year, 3 years about a banned account; only this job may delete (below)
--   private.identity_marks             1 year after the account's deletion, 3 years for a ban's marks; the
--                                      marks of a live account stay, as before
--   private.deleted_identities         1 year after the deletion, 3 years when the account was banned
--   private.support_requests           3 years after the last exchange (the request or its last reply), with
--                                      its messages
--   public.purchase_events,            10 years after the event (accounting law)
--   private.purchase_credits
--
-- and `outbox-cleanup` now also deletes dead letters (failed events nobody replayed) 30 days after they
-- failed, like discarded ones. Jobs already in place: private.ips 180 days and private.devices a year after
-- their last use (device-reports-prune), private.sms_sends 30 days (sms-sends-cleanup), delivered events 7
-- days (outbox-cleanup).
--
-- "Banned": the account is banned now, or it was when it was deleted (its ban marks keep its id, see
-- private.banned_account). The periods are maximums: a record goes earlier with its account when the account
-- is erased (moderation_log, staff_notes and account_links cascade).
--
-- The record of an account kept for safety (private.account_deletions, 20260928000131) held its email, phone
-- and Apple or Google ids in clear. It now keeps which kinds of identity existed and the sign-ins' providers
-- and dates only; the digests in private.deleted_identities do the linking, and sophros finds such an account
-- from a full email or phone number through them (admin_users). Existing records are converted.

-- MARK: Helpers

-- Banned now, or banned when it was deleted: the ban's identity marks outlive the account and keep its id.
create function private.banned_account(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_user is not null and (
    exists (select 1 from public.profiles where id = p_user and moderation = 'banned')
    or exists (select 1 from private.identity_marks where user_id = p_user and state = 'banned'));
$$;

-- How long a moderation record about this account is kept.
create function private.moderation_retention(p_user uuid)
returns interval
language sql
stable
security definer
set search_path = ''
as $$
  select case when private.banned_account(p_user) then interval '3 years' else interval '1 year' end;
$$;

-- MARK: Identity marks outlive the account for a set time

-- When the account that left the mark was deleted: set when it is kept for safety (profiles.deleted_at) or
-- erased. Null while it lives.
alter table private.identity_marks add column deleted_at timestamptz;

-- Marks of accounts already gone: their deletion date is unknown, the period starts now.
update private.identity_marks m
  set deleted_at = coalesce((select p.deleted_at from public.profiles p where p.id = m.user_id), now())
  where not exists (select 1 from public.profiles p where p.id = m.user_id and p.deleted_at is null);

create index identity_marks_deleted_idx on private.identity_marks (deleted_at) where deleted_at is not null;

-- A mark written or taken over (on_moderation, inherit_hold) follows its account's state.
create function private.identity_mark_deleted_at()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.profiles where id = new.user_id) then
    new.deleted_at := (select deleted_at from public.profiles where id = new.user_id);
  else
    new.deleted_at := coalesce(new.deleted_at, now());
  end if;
  return new;
end;
$$;

create trigger identity_marks_deleted_at before insert or update of user_id on private.identity_marks
  for each row execute function private.identity_mark_deleted_at();

-- The account kept for safety (retain_deleted_account), or erased (its Auth user deleted, the profile with it).
create function private.on_account_gone()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    update private.identity_marks set deleted_at = coalesce(deleted_at, now()) where user_id = old.id;
  else
    update private.identity_marks set deleted_at = new.deleted_at where user_id = new.id;
  end if;
  return null;
end;
$$;

create trigger profiles_marks_deleted after update of deleted_at on public.profiles
  for each row when (new.deleted_at is distinct from old.deleted_at) execute function private.on_account_gone();
create trigger profiles_marks_erased after delete on public.profiles
  for each row execute function private.on_account_gone();

-- MARK: No identity in clear in the deletion record

-- What the record keeps of the sign-in identities: which kinds there were, and each Apple or Google sign-in's
-- provider and dates. Never a value: no email, number, provider id or provider email.
create function private.identities_summary(p_identities jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'email', coalesce(p_identities ->> 'email', '') <> '',
    'phone', coalesce(p_identities ->> 'phone', '') <> '',
    'oauth', coalesce((
      select jsonb_agg(jsonb_build_object('provider', o ->> 'provider', 'createdAt', o -> 'createdAt',
        'lastSignInAt', o -> 'lastSignInAt'))
      from jsonb_array_elements(case when jsonb_typeof(p_identities -> 'oauth') = 'array'
        then p_identities -> 'oauth' else '[]'::jsonb end) o), '[]'::jsonb));
$$;

-- Existing records: their digests first (retain_deleted_account wrote them from the same values; this only
-- fills a gap), then the clear values go.
insert into private.deleted_identities (kind, hash, user_id)
  select x.kind, x.hash, d.user_id
  from private.account_deletions d
  cross join lateral (
    select 'email' as kind, private.identity_hash('email', private.normalize_email(d.identities ->> 'email')) as hash
    union all
    select 'phone', private.identity_hash('phone', private.normalize_phone(d.identities ->> 'phone'))
    union all
    select 'oauth', private.identity_hash('oauth', (o ->> 'provider') || ':' || (o ->> 'providerId'))
    from jsonb_array_elements(case when jsonb_typeof(d.identities -> 'oauth') = 'array'
      then d.identities -> 'oauth' else '[]'::jsonb end) o
  ) x
  where x.hash is not null
  on conflict do nothing;

update private.account_deletions set identities = private.identities_summary(identities)
  where identities <> '{}';

-- 20260928000131, storing the summary instead of the identities.
create or replace function public.retain_deleted_account(p_user uuid)
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
      'oauth', (select coalesce(jsonb_agg(jsonb_build_object('provider', i.provider,
          'createdAt', i.created_at, 'lastSignInAt', i.last_sign_in_at)), '[]')
        from auth.identities i where i.user_id = u.id and i.provider not in ('email', 'phone')))
    into v_identities
  from auth.users u where u.id = p_user;

  insert into private.account_deletions (user_id, basis, refs, identities)
    values (p_user, v_why ->> 'basis', v_why -> 'refs', private.identities_summary(coalesce(v_identities, '{}')));
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

-- 20260928000132, plus a kept account found by a full email or phone number: its Auth user moved to a
-- placeholder, only the digests of its identities know them.
create or replace function public.admin_users(
  p_actor text, p_query text default '', p_filter text default 'all', p_limit int default 50, p_offset int default 0
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_query text := nullif(trim(coalesce(p_query, '')), '');
  v_digits text := private.normalize_phone(p_query);
  v_email_hash text := private.identity_hash('email', private.normalize_email(nullif(trim(coalesce(p_query, '')), '')));
  v_phone_hash text := private.identity_hash('phone', private.normalize_phone(p_query));
  v_result jsonb;
begin
  perform private.require_staff(p_actor, 'support');
  v_result := coalesce((
    select jsonb_agg(to_jsonb(r) - 'sort_key' order by r.sort_key desc, r.created_at desc)
    from (
      select p.id, p.name, u.email, u.phone, p.moderation, p.paused, p.deleted_at, p.onboarded_at, p.created_at, p.last_active_at,
             (select max(d.last_seen_at) from private.devices d where d.user_id = p.id) as last_opened_at,
             (private.admin_person(p.id) ->> 'photo') as photo,
             coalesce(w.premium_until > now(), false) as premium,
             f.flags, rp.reports,
             case p_filter
               when 'flagged' then f.flags::numeric
               when 'reported' then rp.reports::numeric
               when 'active' then extract(epoch from p.last_active_at)::numeric
               else extract(epoch from p.created_at)::numeric
             end as sort_key
      from public.profiles p
      join auth.users u on u.id = p.id
      left join public.wallets w on w.user_id = p.id
      cross join lateral (select count(*) as flags from public.media_flags mf
        where mf.user_id = p.id and mf.created_at > now() - interval '30 days') f
      cross join lateral (select count(*) as reports from public.reports r
        where r.reported = p.id and r.created_at > now() - interval '30 days') rp
      where (v_query is null
             or p.id::text = lower(v_query)
             or u.email ilike private.like_pattern(v_query)
             or p.name ilike private.like_pattern(v_query)
             or (char_length(v_digits) >= 4 and u.phone like '%' || v_digits || '%')
             or (p.deleted_at is not null and exists (
               select 1 from private.deleted_identities di
               where di.user_id = p.id
                 and ((di.kind = 'email' and di.hash = v_email_hash) or (di.kind = 'phone' and di.hash = v_phone_hash)))))
        and case p_filter
              when 'held' then p.moderation is not null
              when 'review' then p.moderation = 'review'
              when 'selfie' then p.moderation = 'selfie'
              when 'banned' then p.moderation = 'banned'
              when 'deleted' then p.deleted_at is not null
              when 'flagged' then f.flags > 0
              when 'reported' then rp.reports > 0
              when 'premium' then coalesce(w.premium_until > now(), false)
              else true
            end
      order by sort_key desc, p.created_at desc
      limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)
    ) r), '[]');
  perform private.audit(p_actor, 'user.search', null, null, null, jsonb_build_object(
    'query', v_query, 'filter', p_filter, 'offset', greatest(p_offset, 0), 'results', jsonb_array_length(v_result)));
  return v_result;
end;
$$;

-- MARK: The audit log, purged on schedule only

-- Past its period (1 year, 3 about a banned account).
create function private.audit_expired(p_user uuid, p_created_at timestamptz)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_created_at < now() - private.moderation_retention(p_user);
$$;

-- Still append-only for everyone (20260927000007, 20260928000092): the one exception is a row past its period,
-- deleted by private.purge_expired(), which sets drafft.purging for its own transaction. Even with the
-- setting, a row still within its period can't be deleted, and nothing can be edited.
create function private.audit_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' and current_setting('drafft.purging', true) = 'on'
     and private.audit_expired(old.user_id, old.created_at) then
    return old;
  end if;
  raise exception 'the audit log is append-only' using errcode = 'P0001', hint = 'append_only';
end;
$$;

drop trigger admin_audit_append_only on private.admin_audit;
create trigger admin_audit_append_only before update or delete on private.admin_audit
  for each row execute function private.audit_guard();

-- MARK: The purge

-- Everything past its period, in one pass. Returns how many rows each step deleted (logged by pg_cron).
create function private.purge_expired()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_counts jsonb := '{}'::jsonb;
  v_count bigint;
begin
  delete from public.reports where handled_at < now() - interval '1 year';
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('reports', v_count);

  -- The entry behind a hold still in force explains it: it stays as long as the hold.
  delete from private.moderation_log l
    where l.created_at < now() - private.moderation_retention(l.user_id)
      and not (exists (select 1 from public.profiles p where p.id = l.user_id and p.moderation is not null)
               and not exists (select 1 from private.moderation_log x
                               where x.user_id = l.user_id and (x.created_at, x.id) > (l.created_at, l.id)));
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('moderation_log', v_count);

  delete from private.staff_notes where created_at < now() - private.moderation_retention(user_id);
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('staff_notes', v_count);

  -- From the review, or from the flag when nobody looked at it (a silent chat check).
  delete from public.media_flags where coalesce(reviewed_at, created_at) < now() - private.moderation_retention(user_id);
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('media_flags', v_count);

  delete from private.account_links
    where created_at < now() - greatest(private.moderation_retention(user_id), private.moderation_retention(deleted_user_id));
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('account_links', v_count);

  perform set_config('drafft.purging', 'on', true);
  delete from private.admin_audit where private.audit_expired(user_id, created_at);
  get diagnostics v_count = row_count;
  perform set_config('drafft.purging', '', true);
  v_counts := v_counts || jsonb_build_object('admin_audit', v_count);

  delete from private.identity_marks
    where deleted_at < now() - case when state = 'banned' then interval '3 years' else interval '1 year' end;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('identity_marks', v_count);

  -- The digests of a kept account's identities, and what its record says of them.
  with expired as (
    select d.user_id from private.account_deletions d
    where d.deleted_at < now() - case when d.basis = 'ban' or private.banned_account(d.user_id)
                                      then interval '3 years' else interval '1 year' end
  ), gone as (
    delete from private.deleted_identities i using expired e where i.user_id = e.user_id returning 1
  ), cleared as (
    update private.account_deletions d set identities = '{}'
      from expired e where d.user_id = e.user_id and d.identities <> '{}' returning 1
  )
  select count(*) into v_count from gone;
  v_counts := v_counts || jsonb_build_object('deleted_identities', v_count);

  delete from private.support_requests r
    where greatest(r.created_at, (select max(m.created_at) from private.support_messages m where m.request_id = r.id))
      < now() - interval '3 years';
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('support_requests', v_count);

  delete from public.purchase_events where event_at < now() - interval '10 years';
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('purchase_events', v_count);

  delete from private.purchase_credits where greatest(created_at, credited_at, refunded_at) < now() - interval '10 years';
  get diagnostics v_count = row_count;
  return v_counts || jsonb_build_object('purchase_credits', v_count);
end;
$$;

revoke all on function private.banned_account(uuid), private.moderation_retention(uuid),
  private.identity_mark_deleted_at(), private.on_account_gone(), private.identities_summary(jsonb),
  private.audit_expired(uuid, timestamptz), private.audit_guard(), private.purge_expired()
  from public, anon, authenticated;

select cron.schedule('privacy-purge', '47 3 * * *', 'select private.purge_expired()');

-- Dead letters (failed, never replayed nor discarded) go 30 days after they failed, like discarded ones: the
-- policy's "technical sending queues, 30 days at most". The rest is unchanged from 20260928000121.
select cron.unschedule('outbox-cleanup');
select cron.schedule('outbox-cleanup', '17 3 * * *', $$
  delete from private.outbox where delivered_at < now() - interval '7 days';
  delete from private.outbox where discarded_at < now() - interval '30 days';
  delete from private.outbox where failed_at < now() - interval '30 days' and delivered_at is null;
$$);
