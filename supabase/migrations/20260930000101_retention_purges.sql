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
--   private.identity_marks             1 year after the account's deletion, 3 years for a banned account; the
--                                      marks of a live account, or of a kept one still on hold or banned, stay
--   private.deleted_identities         1 year after the deletion, 3 years for a banned account; kept while the
--                                      kept account is still on hold or banned
--   private.banned_accounts            3 years after the account is erased
--   private.support_requests           3 years after the last exchange (the request or its last reply), with
--                                      its messages
--   public.purchase_events,            10 years after the event (accounting law)
--   private.purchase_credits
--
-- Periods come from one place, private.retention_period. The periods are maximums: a record goes earlier with
-- its account when the account is erased (moderation_log, staff_notes and account_links cascade).
--
-- `outbox-cleanup` becomes private.outbox_cleanup() and now also deletes dead letters (failed, then neither
-- replayed nor discarded) 30 days after their last failure, like discarded ones, except erasures
-- (outbox_policies.erasure): a failed erasure stays in sophros' Failed events, and in the team's alerts, until
-- someone replays or discards it. Jobs already in place: private.ips 180 days and private.devices a year
-- after their last use (device-reports-prune), private.sms_sends 30 days (sms-sends-cleanup).
--
-- Both jobs record each run in private.job_runs (what each step deleted); ops_check opens an incident, and
-- ops_daily says so, when one of them has not completed in 26 hours or pg_cron recorded a failed run since.
--
-- "Banned": private.banned_accounts, written when an account is banned, removed when the ban is lifted, and
-- kept 3 years after the account is erased, so a record about it keeps its 3 years without depending on
-- the identity marks, which have their own period.
--
-- The record of an account kept for safety (private.account_deletions, 20260928000131) held its email, phone
-- and Apple or Google ids in clear. It now keeps which kinds of identity existed and the sign-ins' providers
-- and dates only (a check enforces the shape); the digests in private.deleted_identities do the linking, and
-- sophros finds such an account from a full email or phone number through them (admin_users). Existing
-- records are converted.
--
-- migration-guard: allow destructive drop - replaces the audit log's append-only trigger by its guard, and
-- the outbox-cleanup job by a function doing the same and more

-- MARK: Periods

-- Every period the purges use, in one place. `p_banned`: the record is about a banned account.
create function private.retention_period(p_data text, p_banned boolean default false)
returns interval
language plpgsql
immutable
set search_path = ''
as $$
begin
  case p_data
    -- Moderation log, staff notes, photo flags, account links, team access log.
    when 'moderation' then return case when p_banned then interval '3 years' else interval '1 year' end;
    -- Identity marks and digests, from the account's deletion.
    when 'identity' then return case when p_banned then interval '3 years' else interval '1 year' end;
    -- The ban itself, from the account's erasure.
    when 'ban' then return interval '3 years';
    when 'report' then return interval '1 year';
    when 'support' then return interval '3 years';
    when 'purchase' then return interval '10 years';
    -- Outbox: delivered rows, and dropped, discarded or failed ones.
    when 'outbox_delivered' then return interval '7 days';
    when 'outbox_dead' then return interval '30 days';
    when 'job_runs' then return interval '90 days';
    else
      -- An unknown name would compare as null and delete nothing, silently.
      raise exception 'unknown retention period %', p_data;
  end case;
end;
$$;

-- MARK: Banned accounts

-- Who is or was banned: kept while the account exists, then 3 years after its erasure (`erased_at`).
create table private.banned_accounts (
  -- The account may be erased since: no foreign key.
  user_id uuid primary key,
  banned_at timestamptz not null default now(),
  erased_at timestamptz
);

create index banned_accounts_erased_idx on private.banned_accounts (erased_at) where erased_at is not null;

-- Accounts banned now, then the bans of accounts already erased, which only their marks remember.
insert into private.banned_accounts (user_id, banned_at)
  select p.id, coalesce((select max(l.created_at) from private.moderation_log l where l.user_id = p.id), now())
  from public.profiles p where p.moderation = 'banned';
insert into private.banned_accounts (user_id, banned_at, erased_at)
  select m.user_id, min(m.created_at), now() from private.identity_marks m
  where m.state = 'banned' and not exists (select 1 from public.profiles p where p.id = m.user_id)
  group by m.user_id
  on conflict (user_id) do nothing;

create function private.track_ban()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    update private.banned_accounts set erased_at = now() where user_id = old.id;
  elsif new.moderation = 'banned' then
    insert into private.banned_accounts (user_id) values (new.id)
      on conflict (user_id) do update set banned_at = now(), erased_at = null;
  else
    -- A ban lifted (an appeal): the account is no longer banned, its records take the usual period.
    delete from private.banned_accounts where user_id = new.id;
  end if;
  return null;
end;
$$;

create trigger profiles_track_ban after update of moderation on public.profiles
  for each row when (new.moderation is distinct from old.moderation
    and (new.moderation = 'banned' or old.moderation = 'banned'))
  execute function private.track_ban();
create trigger profiles_track_ban_erased after delete on public.profiles
  for each row when (old.moderation = 'banned') execute function private.track_ban();

create function private.banned_account(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from private.banned_accounts where user_id = p_user);
$$;

-- How long a moderation record about this account is kept.
create function private.moderation_retention(p_user uuid)
returns interval
language sql
stable
security definer
set search_path = ''
as $$
  select private.retention_period('moderation', private.banned_account(p_user));
$$;

-- MARK: Identity marks outlive the account for a set time

-- When the account that left the mark was deleted: kept for safety (profiles.deleted_at) or erased. Null
-- while it lives.
alter table private.identity_marks add column deleted_at timestamptz;

-- Marks of a kept account take its deletion date; those of accounts erased before this migration, whose
-- date is unknown, start their period now.
update private.identity_marks m
  set deleted_at = coalesce((select p.deleted_at from public.profiles p where p.id = m.user_id), now())
  where not exists (select 1 from public.profiles p where p.id = m.user_id and p.deleted_at is null);

create index identity_marks_deleted_idx on private.identity_marks (deleted_at) where deleted_at is not null;

-- A mark written or taken over (on_moderation, inherit_hold) takes its account's deletion date (null while
-- it lives).
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

-- The account kept for safety (retain_deleted_account), or erased (its Auth user deleted, the profile with
-- it). A kept account erased later keeps its first date.
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
-- provider and dates. Never a value: no email, number, provider id or provider email. A summary maps to
-- itself, so the check below can hold it to this shape.
create function private.identities_summary(p_identities jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'email', case jsonb_typeof(p_identities -> 'email')
               when 'boolean' then (p_identities -> 'email')::boolean
               else coalesce(p_identities ->> 'email', '') <> '' end,
    'phone', case jsonb_typeof(p_identities -> 'phone')
               when 'boolean' then (p_identities -> 'phone')::boolean
               else coalesce(p_identities ->> 'phone', '') <> '' end,
    'oauth', coalesce((
      select jsonb_agg(jsonb_build_object('provider', o ->> 'provider', 'createdAt', o -> 'createdAt',
        'lastSignInAt', o -> 'lastSignInAt'))
      from jsonb_array_elements(case when jsonb_typeof(p_identities -> 'oauth') = 'array'
        then p_identities -> 'oauth' else '[]'::jsonb end) o), '[]'::jsonb));
$$;

-- When the purge cleared the identities (identities '{}' from then on).
alter table private.account_deletions add column identities_purged_at timestamptz;

-- Records written before: their digests first (retain_deleted_account wrote them from the same values; this
-- only fills a gap), then the clear values go. Returns how many records it converted.
create function private.convert_deletion_identities()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count bigint;
begin
  insert into private.deleted_identities (kind, hash, user_id)
    select x.kind, x.hash, d.user_id
    from private.account_deletions d
    cross join lateral (
      select 'email' as kind, private.identity_hash('email', private.normalize_email(d.identities ->> 'email')) as hash
      where jsonb_typeof(d.identities -> 'email') = 'string'
      union all
      select 'phone', private.identity_hash('phone', private.normalize_phone(d.identities ->> 'phone'))
      where jsonb_typeof(d.identities -> 'phone') = 'string'
      union all
      select 'oauth', private.identity_hash('oauth', (o ->> 'provider') || ':' || (o ->> 'providerId'))
      from jsonb_array_elements(case when jsonb_typeof(d.identities -> 'oauth') = 'array'
        then d.identities -> 'oauth' else '[]'::jsonb end) o
      where o ->> 'providerId' is not null
    ) x
    where x.hash is not null
    on conflict do nothing;
  update private.account_deletions set identities = private.identities_summary(identities)
    where identities_purged_at is null and identities is distinct from private.identities_summary(identities);
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

select private.convert_deletion_identities();

-- Only summaries from now on; '{}' once the purge cleared them.
alter table private.account_deletions
  add constraint account_deletions_identities_summary check (case when identities_purged_at is null
    then identities = private.identities_summary(identities) else identities = '{}' end);

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

-- MARK: Job runs

-- The daily jobs whose runs are watched, and since when (a job that never ran is late 26 hours after this).
create table private.watched_jobs (
  job text primary key,
  since timestamptz not null default now()
);

insert into private.watched_jobs (job) values ('privacy-purge'), ('outbox-cleanup');

-- One row per run, written inside the run's own transaction: a run that fails leaves none.
create table private.job_runs (
  id bigint generated always as identity primary key,
  job text not null references private.watched_jobs (job),
  -- The run's transaction: private.purging() recognises the purge by it.
  xact bigint not null default txid_current(),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  -- What each step deleted.
  counts jsonb,
  check ((finished_at is null) = (counts is null))
);

create index job_runs_job_idx on private.job_runs (job, finished_at desc);

create function private.start_job(p_job text)
returns bigint
language sql
security definer
set search_path = ''
as $$
  insert into private.job_runs (job) values (p_job) returning id;
$$;

create function private.finish_job(p_run bigint, p_counts jsonb)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  update private.job_runs set finished_at = now(), counts = p_counts where id = p_run returning counts;
$$;

-- True inside a running privacy purge only: a row in private.job_runs for this very transaction, which only
-- functions owned by the database owner can write. A setting (set_config) would be open to any role.
create function private.purging()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from private.job_runs
    where job = 'privacy-purge' and xact = txid_current() and finished_at is null);
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
-- deleted by private.purge_expired(). Even inside the purge, a row within its period can't be deleted, and
-- nothing can be edited.
create function private.audit_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' and private.purging() and private.audit_expired(old.user_id, old.created_at) then
    return old;
  end if;
  raise exception 'the audit log is append-only' using errcode = 'P0001', hint = 'append_only';
end;
$$;

drop trigger admin_audit_append_only on private.admin_audit;
create trigger admin_audit_append_only before update or delete on private.admin_audit
  for each row execute function private.audit_guard();

-- MARK: The purge

-- For the date prefilters below: each purge first narrows on the shortest period, which an index serves,
-- then applies the period of each row.
create index reports_handled_idx on public.reports (handled_at) where handled_at is not null;
create index moderation_log_created_idx on private.moderation_log (created_at);
create index staff_notes_created_idx on private.staff_notes (created_at);
create index account_links_created_idx on private.account_links (created_at);
create index support_requests_created_idx on private.support_requests (created_at);
create index purchase_events_event_idx on public.purchase_events (event_at);
create index purchase_credits_created_idx on private.purchase_credits (created_at);

-- Everything past its period, in one transaction. Records what each step deleted in private.job_runs and
-- returns it.
create function private.purge_expired()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run bigint := private.start_job('privacy-purge');
  v_short interval := private.retention_period('moderation', false);
  v_counts jsonb := '{}'::jsonb;
  v_count bigint;
  v_cleared bigint;
begin
  -- First: an account forgotten as banned takes the usual periods in the steps below.
  delete from private.banned_accounts where erased_at < now() - private.retention_period('ban');
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('banned_accounts', v_count);

  delete from public.reports where handled_at < now() - private.retention_period('report');
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('reports', v_count);

  -- The entry behind a hold still in force explains it: it stays as long as the hold.
  delete from private.moderation_log l
    where l.created_at < now() - v_short
      and l.created_at < now() - private.moderation_retention(l.user_id)
      and not (exists (select 1 from public.profiles p where p.id = l.user_id and p.moderation is not null)
               and not exists (select 1 from private.moderation_log x
                               where x.user_id = l.user_id and (x.created_at, x.id) > (l.created_at, l.id)));
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('moderation_log', v_count);

  delete from private.staff_notes
    where created_at < now() - v_short and created_at < now() - private.moderation_retention(user_id);
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('staff_notes', v_count);

  -- From the review, or from the flag when nobody looked at it (a silent chat check). A review comes after
  -- the flag, so the flag's own date narrows first.
  delete from public.media_flags
    where created_at < now() - v_short
      and coalesce(reviewed_at, created_at) < now() - private.moderation_retention(user_id);
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('media_flags', v_count);

  delete from private.account_links
    where created_at < now() - v_short
      and created_at < now() - private.retention_period('moderation',
        private.banned_account(user_id) or private.banned_account(deleted_user_id));
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('account_links', v_count);

  delete from private.admin_audit where created_at < now() - v_short and private.audit_expired(user_id, created_at);
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('admin_audit', v_count);

  -- A kept account still on hold or banned keeps its marks: they stop the same person from coming back.
  delete from private.identity_marks m
    where m.deleted_at < now() - private.retention_period('identity', false)
      and m.deleted_at < now() - private.retention_period('identity',
        m.state = 'banned' or private.banned_account(m.user_id))
      and not exists (select 1 from public.profiles p where p.id = m.user_id and p.moderation is not null);
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('identity_marks', v_count);

  -- The digests of a kept account's identities, and what its record says of them; the same exception.
  with expired as (
    select d.user_id from private.account_deletions d
    where d.identities_purged_at is null
      and d.deleted_at < now() - private.retention_period('identity', false)
      and d.deleted_at < now() - private.retention_period('identity', private.banned_account(d.user_id))
      and not exists (select 1 from public.profiles p where p.id = d.user_id and p.moderation is not null)
  ), gone as (
    delete from private.deleted_identities i using expired e where i.user_id = e.user_id returning 1
  ), cleared as (
    update private.account_deletions d set identities = '{}', identities_purged_at = now()
      from expired e where d.user_id = e.user_id returning 1
  )
  select (select count(*) from gone), (select count(*) from cleared) into v_count, v_cleared;
  v_counts := v_counts || jsonb_build_object('deleted_identities', v_count, 'deletion_records_cleared', v_cleared);

  delete from private.support_requests r
    where r.created_at < now() - private.retention_period('support')
      and not exists (select 1 from private.support_messages m
                      where m.request_id = r.id and m.created_at >= now() - private.retention_period('support'));
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('support_requests', v_count);

  delete from public.purchase_events where event_at < now() - private.retention_period('purchase');
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('purchase_events', v_count);

  delete from private.purchase_credits
    where created_at < now() - private.retention_period('purchase')
      and greatest(created_at, credited_at, refunded_at) < now() - private.retention_period('purchase');
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('purchase_credits', v_count);

  delete from private.job_runs where started_at < now() - private.retention_period('job_runs');

  return private.finish_job(v_run, v_counts);
end;
$$;

select cron.schedule('privacy-purge', '47 3 * * *', 'select private.purge_expired()');

-- MARK: The sending queue

-- An erasure that failed stays until the team replays or discards it: dropping it would drop the only trace
-- of data still to erase.
alter table private.outbox_policies add column erasure boolean not null default false;

update private.outbox_policies set erasure = true
  where event in ('media.deleted', 'selfie.delete', 'account.soft_deleted', 'account.moderation', 'stream.user');

-- Delivered rows go after 7 days, dropped and discarded ones after 30 (as before), and now dead letters too,
-- 30 days after their last failure (the policy's "technical sending queues, 30 days at most"), except
-- erasures. How many went, by event, is in the run's counts and the team's daily summary.
create function private.outbox_cleanup()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run bigint := private.start_job('outbox-cleanup');
  v_delivered bigint;
  v_discarded bigint;
  v_dead jsonb;
begin
  delete from private.outbox where delivered_at < now() - private.retention_period('outbox_delivered');
  get diagnostics v_delivered = row_count;
  delete from private.outbox where discarded_at < now() - private.retention_period('outbox_dead');
  get diagnostics v_discarded = row_count;
  with dead as (
    delete from private.outbox o
      where o.failed_at < now() - private.retention_period('outbox_dead')
        and o.delivered_at is null and o.discarded_at is null
        and not coalesce((select p.erasure from private.outbox_policies p where p.event = o.event), false)
      returning o.event
  )
  select coalesce(jsonb_object_agg(event, n), '{}') into v_dead
    from (select event, count(*) as n from dead group by event) d;
  return private.finish_job(v_run,
    jsonb_build_object('delivered', v_delivered, 'discarded', v_discarded, 'deadLetters', v_dead));
end;
$$;

select cron.unschedule('outbox-cleanup');
select cron.schedule('outbox-cleanup', '17 3 * * *', 'select private.outbox_cleanup()');

-- MARK: Alerts

-- 20260928000121, plus the watched jobs behind: no completed run in 26 hours, or a failed one since the last.
create or replace function private.ops_state()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with behind as (
    select w.job, r.last,
      coalesce(r.last, w.since) as since
    from private.watched_jobs w
    left join lateral (select max(finished_at) as last from private.job_runs where job = w.job) r on true
    where greatest(w.since, r.last) < now() - interval '26 hours'
       or exists (select 1 from cron.job j join cron.job_run_details d on d.jobid = j.jobid
                  where j.jobname = w.job and d.status = 'failed' and d.start_time > greatest(w.since, r.last))
  )
  select jsonb_build_object(
    'failed', (select count(*) from private.outbox
               where failed_at is not null and delivered_at is null and discarded_at is null),
    'failedByEvent', coalesce((select jsonb_object_agg(event, n) from (
        select event, count(*) as n from private.outbox
        where failed_at is not null and delivered_at is null and discarded_at is null group by event) f), '{}'),
    'oldestFailedAt', (select min(failed_at) from private.outbox
                       where failed_at is not null and delivered_at is null and discarded_at is null),
    'waiting', (select count(*) from private.outbox
                where delivered_at is null and failed_at is null and discarded_at is null and waiting_for is not null),
    'late', (select count(*) from private.outbox
             where delivered_at is null and failed_at is null and discarded_at is null
               and created_at < now() - interval '30 minutes'),
    'oldestLateAt', (select min(created_at) from private.outbox
                     where delivered_at is null and failed_at is null and discarded_at is null
                       and created_at < now() - interval '30 minutes'),
    'openCircuits', coalesce((select jsonb_agg(provider order by provider) from private.provider_circuits
                              where state <> 'closed'), '[]'),
    'oldestOpenCircuitAt', (select min(opened_at) from private.provider_circuits where state <> 'closed'),
    'jobsBehind', coalesce((select jsonb_agg(jsonb_build_object('job', job, 'lastRunAt', last) order by job)
                            from behind), '[]'),
    'oldestJobBehindAt', (select min(since) from behind));
$$;

-- 20260928000121, plus a job behind as a sign of trouble.
create or replace function private.ops_check()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_state jsonb := private.ops_state();
  v_trouble boolean;
  v_oldest timestamptz;
  v_incident private.ops_incidents;
  v_id bigint;
begin
  v_trouble := (v_state ->> 'failed')::int > 0 or (v_state ->> 'late')::int > 0
    or jsonb_array_length(v_state -> 'openCircuits') > 0 or jsonb_array_length(v_state -> 'jobsBehind') > 0;
  v_oldest := least((v_state ->> 'oldestFailedAt')::timestamptz, (v_state ->> 'oldestLateAt')::timestamptz,
    (v_state ->> 'oldestOpenCircuitAt')::timestamptz, (v_state ->> 'oldestJobBehindAt')::timestamptz);
  select * into v_incident from private.ops_incidents where closed_at is null for update;

  if v_trouble and v_incident.id is null then
    insert into private.ops_incidents default values returning * into v_incident;
    perform private.queue_ops_alert('incident', v_incident.id, v_state);
  elsif v_trouble and v_incident.reminded_at is null and v_oldest < now() - interval '1 hour' then
    update private.ops_incidents set reminded_at = now() where id = v_incident.id;
    perform private.queue_ops_alert('reminder', v_incident.id,
      v_state || jsonb_build_object('openedAt', v_incident.opened_at));
  elsif not v_trouble and v_incident.id is not null then
    update private.ops_incidents set closed_at = now() where id = v_incident.id;
  end if;

  for v_id in
    select id from private.ops_alerts
    where sent_at is null and attempts < 5 and created_at > now() - interval '1 day'
      and created_at < now() - interval '1 minute'
    order by id
  loop
    perform private.send_ops_alert(v_id);
  end loop;
end;
$$;

-- 20260928000121, plus what the last runs of the watched jobs deleted.
create or replace function private.ops_daily()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.queue_ops_alert('daily', null, private.ops_state() || jsonb_build_object(
    'delivered', (select count(*) from private.outbox where delivered_at > now() - interval '1 day'),
    'expired', (select count(*) from private.outbox
                where discarded_at > now() - interval '1 day' and discard_reason = 'expired'),
    'discarded', (select count(*) from private.outbox
                  where discarded_at > now() - interval '1 day' and discarded_by is not null),
    'newlyFailed', (select count(*) from private.outbox where failed_at > now() - interval '1 day'),
    'incidents', (select count(*) from private.ops_incidents where opened_at > now() - interval '1 day'),
    'jobs', coalesce((select jsonb_object_agg(r.job, r.counts) from (
        select distinct on (job) job, counts from private.job_runs
        where finished_at > now() - interval '1 day' order by job, finished_at desc) r), '{}')));
end;
$$;

revoke all on function private.retention_period(text, boolean), private.track_ban(), private.banned_account(uuid),
  private.moderation_retention(uuid), private.identity_mark_deleted_at(), private.on_account_gone(),
  private.identities_summary(jsonb), private.convert_deletion_identities(), private.start_job(text),
  private.finish_job(bigint, jsonb), private.purging(), private.audit_expired(uuid, timestamptz),
  private.audit_guard(), private.purge_expired(), private.outbox_cleanup()
  from public, anon, authenticated;
