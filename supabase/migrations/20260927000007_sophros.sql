-- sophros, the team's moderation and support dashboard (its own repository, one deployment per
-- environment). It signs its staff in itself (Cloudflare Access) and reaches this database with the
-- secret key only, through the `admin_*` functions below: service role only, never the app.
--
-- The database doesn't trust the dashboard blindly: every call names its actor (the staff member's
-- email), and each function checks that person's role here, in private.staff, then writes what they did
-- to private.admin_audit, which can't be edited or deleted. Roles, each with the rights of the one before:
--
--   support    read accounts, support requests and reports; answer support, add notes
--   moderator  holds (review, selfie, ban), photos, flags, reports, conversations and selfies
--   admin      lift a ban, manage the staff, read the whole audit log
--
-- Reading a conversation or a selfie is logged with a reason (admin_log), like any action.

-- MARK: Staff and audit

create table private.staff (
  email text primary key check (email = lower(trim(email)) and char_length(email) between 3 and 320),
  role text not null check (role in ('support', 'moderator', 'admin')),
  created_at timestamptz not null default now(),
  created_by text,
  last_seen_at timestamptz,
  disabled_at timestamptz
);

create table private.admin_audit (
  id bigint generated always as identity primary key,
  actor text not null,
  action text not null check (char_length(action) <= 60),
  -- The account concerned. No foreign key: the trail outlives the account.
  user_id uuid,
  -- Anything else it was about: a report, a photo, a support request, a conversation.
  target text check (char_length(target) <= 200),
  reason text check (char_length(reason) <= 1000),
  details jsonb not null default '{}',
  created_at timestamptz not null default now()
);

create index admin_audit_user_idx on private.admin_audit (user_id, created_at desc);
create index admin_audit_created_idx on private.admin_audit (created_at desc);
create index admin_audit_actor_idx on private.admin_audit (actor, created_at desc);

-- Append-only, whoever asks.
create function private.audit_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'the audit log is append-only' using errcode = 'P0001', hint = 'append_only';
end;
$$;

create trigger admin_audit_append_only before update or delete on private.admin_audit
  for each row execute function private.audit_append_only();

-- Staff notes on an account, for the next person who opens it.
create table private.staff_notes (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  author text not null,
  body text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);

create index staff_notes_user_idx on private.staff_notes (user_id, created_at desc);

-- Who did what, on the rows the team works through.
alter table private.moderation_log
  add column actor text default nullif(current_setting('drafft.moderation_actor', true), '');
alter table public.media_flags add column reviewed_at timestamptz, add column reviewed_by text;
alter table public.reports add column handled_by text, add column resolution text check (char_length(resolution) <= 1000);
alter table private.support_requests add column handled_by text;
alter table private.data_requests add column fulfilled_by text;

create index media_flags_open_idx on public.media_flags (created_at desc) where reviewed_at is null;

create function private.staff_rank(p_role text)
returns int
language sql
immutable
set search_path = ''
as $$
  select case p_role when 'admin' then 3 when 'moderator' then 2 when 'support' then 1 else 0 end;
$$;

-- Fails unless the actor is active staff with at least this role.
create function private.require_staff(p_actor text, p_role text)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role text;
begin
  select role into v_role from private.staff where email = lower(trim(p_actor)) and disabled_at is null;
  if private.staff_rank(v_role) < private.staff_rank(p_role) then
    perform private.fail('forbidden', 'not allowed');
  end if;
end;
$$;

create function private.audit(
  p_actor text, p_action text, p_user uuid, p_target text default null, p_reason text default null,
  p_details jsonb default '{}'
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into private.admin_audit (actor, action, user_id, target, reason, details)
    values (lower(trim(p_actor)), p_action, p_user, p_target, nullif(trim(p_reason), ''), coalesce(p_details, '{}'));
$$;

create function private.require_reason(p_reason text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if coalesce(trim(p_reason), '') = '' then
    perform private.fail('reason_required', 'say why');
  end if;
end;
$$;

-- An account as lists show it: name, hold, and a photo (a video's poster).
create function private.admin_person(p_user uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case when p_user is null then null else coalesce((
    select jsonb_build_object('id', p.id, 'name', p.name, 'moderation', p.moderation, 'photo', (
      select coalesce(m.poster_key, m.key) from public.profile_media m
      where m.user_id = p.id order by m.status = 'approved' desc, m.position limit 1))
    from public.profiles p where p.id = p_user),
    jsonb_build_object('id', p_user, 'deleted', true)) end;
$$;

-- What a reviewer needs to know about the account behind a photo, next to it.
create function private.admin_account_brief(p_user uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'createdAt', p.created_at,
    'lastActiveAt', p.last_active_at,
    'age', private.age_of(p.birthdate),
    'gender', p.gender,
    'onboarded', p.onboarded_at is not null,
    'flags30d', (select count(*) from public.media_flags f where f.user_id = p.id and f.created_at > now() - interval '30 days'),
    'reports30d', (select count(distinct r.reporter) from public.reports r
      where r.reported = p.id and r.created_at > now() - interval '30 days'),
    'holds', (select count(*) from private.moderation_log l where l.user_id = p.id and l.state is not null),
    'photos', (select coalesce(jsonb_agg(jsonb_build_object('key', coalesce(m.poster_key, m.key), 'status', m.status)
        order by m.position), '[]') from public.profile_media m where m.user_id = p.id))
  from public.profiles p where p.id = p_user;
$$;

-- ILIKE pattern that matches the text as typed.
create function private.like_pattern(p_text text)
returns text
language sql
immutable
set search_path = ''
as $$
  select '%' || replace(replace(replace(p_text, '\', '\\'), '%', '\%'), '_', '\_') || '%';
$$;

-- MARK: Staff

-- At each request: the actor's role, or null for someone who isn't (or no longer) staff.
create function public.admin_whoami(p_email text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role text;
begin
  update private.staff set last_seen_at = now()
    where email = lower(trim(p_email)) and disabled_at is null
      and (last_seen_at is null or last_seen_at < now() - interval '5 minutes');
  select role into v_role from private.staff where email = lower(trim(p_email)) and disabled_at is null;
  return v_role;
end;
$$;

create function public.admin_staff_list(p_actor text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_staff(p_actor, 'admin');
  return coalesce((select jsonb_agg(to_jsonb(s) order by s.disabled_at nulls first, s.email) from private.staff s), '[]');
end;
$$;

-- Adds, changes or (role null) disables a staff member. Nobody changes their own role.
create function public.admin_set_staff(p_actor text, p_email text, p_role text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text := lower(trim(p_email));
begin
  perform private.require_staff(p_actor, 'admin');
  if v_email = lower(trim(p_actor)) then
    perform private.fail('own_role', 'you can''t change your own role');
  end if;
  if p_role is null then
    update private.staff set disabled_at = now() where email = v_email and disabled_at is null;
  else
    if private.staff_rank(p_role) = 0 then
      perform private.fail('invalid_role', 'unknown role');
    end if;
    insert into private.staff (email, role, created_by) values (v_email, p_role, lower(trim(p_actor)))
      on conflict (email) do update set role = excluded.role, disabled_at = null;
  end if;
  perform private.audit(p_actor, 'staff.set', null, v_email, null, jsonb_build_object('role', p_role));
end;
$$;

-- MARK: Overview

-- What waits for the team: each queue's size and its oldest item, for triage. No usage figures: sophros
-- is for moderation, not metrics.
create function public.admin_overview(p_actor text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_staff(p_actor, 'support');
  return (
    with held as (
      select p.id, p.moderation,
             exists (select 1 from private.selfie_checks c where c.user_id = p.id) as has_selfie,
             (select max(l.created_at) from private.moderation_log l where l.user_id = p.id) as since
      from public.profiles p where p.moderation is not null
    ),
    pending_media as (
      select coalesce(review_requested_at, created_at) as at from public.profile_media
      where status = 'pending' and (review_requested_at is not null or created_at < now() - interval '5 minutes')
    )
    select jsonb_build_object(
      'holds', jsonb_build_object(
        'review', (select count(*) from held where moderation = 'review'),
        'selfie', (select count(*) from held where moderation = 'selfie'),
        'banned', (select count(*) from held where moderation = 'banned')),
      'queues', jsonb_build_object(
        'selfies', (select jsonb_build_object('count', count(*), 'oldest', min(since)) from held
          where moderation = 'review' and has_selfie),
        'reviews', (select jsonb_build_object('count', count(*), 'oldest', min(since)) from held
          where moderation = 'review' and not has_selfie),
        'selfieOwed', (select jsonb_build_object('count', count(*), 'oldest', min(since)) from held
          where moderation = 'selfie'),
        'reports', (select jsonb_build_object('count', count(*), 'oldest', min(created_at)) from public.reports
          where handled_at is null),
        'support', (select jsonb_build_object('count', count(*), 'oldest', min(created_at)) from private.support_requests
          where handled_at is null),
        'exports', (select jsonb_build_object('count', count(*), 'oldest', min(created_at)) from private.data_requests
          where fulfilled_at is null),
        'photos', (select jsonb_build_object('count', count(*), 'oldest', min(at)) from pending_media),
        'flags', (select jsonb_build_object('count', count(*), 'oldest', min(created_at)) from public.media_flags
          where reviewed_at is null)))
  );
end;
$$;

-- MARK: Accounts

-- Search by id, email, name or phone digits. Filters: all, held, review, selfie, banned, flagged,
-- reported, premium, active (most recently active first).
create function public.admin_users(
  p_actor text, p_query text default '', p_filter text default 'all', p_limit int default 50, p_offset int default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_query text := nullif(trim(coalesce(p_query, '')), '');
  v_digits text := private.normalize_phone(p_query);
begin
  perform private.require_staff(p_actor, 'support');
  return coalesce((
    select jsonb_agg(to_jsonb(r) - 'sort_key' order by r.sort_key desc, r.created_at desc)
    from (
      select p.id, p.name, u.email, u.phone, p.moderation, p.paused, p.onboarded_at, p.created_at, p.last_active_at,
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
             or (char_length(v_digits) >= 4 and u.phone like '%' || v_digits || '%'))
        and case p_filter
              when 'held' then p.moderation is not null
              when 'review' then p.moderation = 'review'
              when 'selfie' then p.moderation = 'selfie'
              when 'banned' then p.moderation = 'banned'
              when 'flagged' then f.flags > 0
              when 'reported' then rp.reports > 0
              when 'premium' then coalesce(w.premium_until > now(), false)
              else true
            end
      order by sort_key desc, p.created_at desc
      limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)
    ) r), '[]');
end;
$$;

-- Everything about one account, for an investigation. Opening it is logged.
create function public.admin_user(p_actor text, p_user uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  perform private.require_staff(p_actor, 'support');
  select jsonb_build_object(
    'profile', to_jsonb(p) - 'voice_levels',
    'auth', jsonb_build_object(
      'email', u.email, 'phone', u.phone, 'emailConfirmedAt', u.email_confirmed_at,
      'phoneConfirmedAt', u.phone_confirmed_at, 'createdAt', u.created_at, 'lastSignInAt', u.last_sign_in_at,
      'signupLanguage', u.raw_user_meta_data ->> 'language',
      'providers', (select coalesce(jsonb_agg(jsonb_build_object(
          'provider', i.provider, 'email', i.email, 'createdAt', i.created_at, 'lastSignInAt', i.last_sign_in_at)
          order by i.created_at), '[]') from auth.identities i where i.user_id = u.id)),
    'sessions', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', s.id, 'createdAt', s.created_at, 'refreshedAt', s.refreshed_at, 'userAgent', s.user_agent, 'ip', s.ip)
        order by coalesce(s.refreshed_at, s.created_at::timestamp) desc), '[]')
      from auth.sessions s where s.user_id = u.id),
    'media', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', m.id, 'kind', m.kind, 'key', m.key, 'posterKey', m.poster_key, 'position', m.position,
        'status', m.status, 'width', m.width, 'height', m.height, 'createdAt', m.created_at,
        'reviewRequestedAt', m.review_requested_at) order by m.position), '[]')
      from public.profile_media m where m.user_id = p.id),
    'sports', (select coalesce(jsonb_agg(jsonb_build_object('sport', s.sport_id, 'perWeek', s.per_week) order by s.position), '[]')
      from public.profile_sports s where s.user_id = p.id),
    'prompts', (select coalesce(jsonb_agg(jsonb_build_object('question', q.question, 'answer', q.answer) order by q.position), '[]')
      from public.profile_prompts q where q.user_id = p.id),
    'wallet', (select to_jsonb(w) - 'user_id' from public.wallets w where w.user_id = p.id),
    'purchases', (select coalesce(jsonb_agg(to_jsonb(e) - 'user_id' order by e.event_at desc), '[]')
      from (select * from public.purchase_events where user_id = p.id order by event_at desc limit 50) e),
    'location', (select jsonb_build_object('lat', extensions.st_y(l.geo::extensions.geometry),
        'lng', extensions.st_x(l.geo::extensions.geometry), 'updatedAt', l.updated_at)
      from private.locations l where l.user_id = p.id),
    'devices', (select coalesce(jsonb_agg(to_jsonb(d) - 'user_id' order by d.last_seen_at desc), '[]')
      from private.devices d where d.user_id = p.id),
    'ips', (select coalesce(jsonb_agg(to_jsonb(i) - 'user_id' order by i.last_seen_at desc), '[]')
      from (select * from private.ips where user_id = p.id order by last_seen_at desc limit 100) i),
    'pushTokens', (select coalesce(jsonb_agg(jsonb_build_object('environment', t.environment, 'updatedAt', t.updated_at,
        'token', left(t.token, 8)) order by t.updated_at desc), '[]')
      from public.push_tokens t where t.user_id = p.id),
    'deviceCheck', (select jsonb_build_object('environment', c.environment, 'updatedAt', c.updated_at, 'flaggedAt', c.flagged_at)
      from private.device_checks c where c.user_id = p.id),
    'moderationLog', (select coalesce(jsonb_agg(jsonb_build_object('state', l.state, 'note', l.note, 'actor', l.actor,
        'createdAt', l.created_at) order by l.created_at desc), '[]')
      from private.moderation_log l where l.user_id = p.id),
    'marks', (select coalesce(jsonb_agg(jsonb_build_object('kind', m.kind, 'state', m.state, 'createdAt', m.created_at)), '[]')
      from private.identity_marks m where m.user_id = p.id),
    'selfies', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'createdAt', c.created_at) order by c.created_at desc), '[]')
      from private.selfie_checks c where c.user_id = p.id),
    'stats', jsonb_build_object(
      'likesGiven', (select count(*) from public.swipes where swiper = p.id and action <> 'pass'),
      'passes', (select count(*) from public.swipes where swiper = p.id and action = 'pass'),
      'likesReceived', (select count(*) from public.swipes where target = p.id and action <> 'pass'),
      'likesGiven24h', (select count(*) from public.swipes where swiper = p.id and action <> 'pass'
        and created_at > now() - interval '1 day'),
      'matches', (select count(*) from public.matches where p.id in (user_a, user_b)),
      'sessions', (select count(*) from public.sessions s join public.matches m on m.id = s.match_id
        where p.id in (m.user_a, m.user_b))),
    'matches', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'createdAt', m.created_at, 'endedAt', m.ended_at,
        'endedBy', m.ended_by, 'other', private.admin_person(case when m.user_a = p.id then m.user_b else m.user_a end))
        order by m.created_at desc), '[]')
      from public.matches m where p.id in (m.user_a, m.user_b)),
    'blocksGiven', (select coalesce(jsonb_agg(jsonb_build_object('person', private.admin_person(b.blocked), 'createdAt', b.created_at)
        order by b.created_at desc), '[]') from public.blocks b where b.blocker = p.id),
    'blocksReceived', (select coalesce(jsonb_agg(jsonb_build_object('person', private.admin_person(b.blocker), 'createdAt', b.created_at)
        order by b.created_at desc), '[]') from public.blocks b where b.blocked = p.id),
    'reportsReceived', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'reason', r.reason, 'details', r.details,
        'reporter', private.admin_person(r.reporter), 'createdAt', r.created_at, 'handledAt', r.handled_at,
        'handledBy', r.handled_by, 'resolution', r.resolution) order by r.created_at desc), '[]')
      from public.reports r where r.reported = p.id),
    'reportsMade', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'reason', r.reason, 'details', r.details,
        'reported', private.admin_person(r.reported), 'createdAt', r.created_at) order by r.created_at desc), '[]')
      from public.reports r where r.reporter = p.id),
    'flags', (select coalesce(jsonb_agg(to_jsonb(f) - 'user_id' order by f.created_at desc), '[]')
      from (select * from public.media_flags where user_id = p.id order by created_at desc limit 100) f),
    'support', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'reference', s.reference, 'topic', s.topic,
        'createdAt', s.created_at, 'handledAt', s.handled_at) order by s.created_at desc), '[]')
      from private.support_requests s where s.user_id = p.id or lower(s.email) = lower(u.email)),
    'dataRequests', (select coalesce(jsonb_agg(to_jsonb(d) - 'user_id' order by d.created_at desc), '[]')
      from private.data_requests d where d.user_id = p.id),
    'notes', (select coalesce(jsonb_agg(to_jsonb(n) - 'user_id' order by n.created_at desc), '[]')
      from private.staff_notes n where n.user_id = p.id),
    'related', public.admin_related(p_actor, p.id)
  )
  into v_result
  from public.profiles p join auth.users u on u.id = p.id
  where p.id = p_user;

  if v_result is null then
    perform private.fail('not_found', 'no such account');
  end if;
  perform private.audit(p_actor, 'user.view', p_user);
  return v_result;
end;
$$;

-- Other accounts that look like the same person: the same install of the app, an IP in common over the
-- last 30 days, or an email, phone or sign-in marked by an account on hold (a deleted one, often).
create function public.admin_related(p_actor text, p_user uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_staff(p_actor, 'support');
  return coalesce((
    select jsonb_agg(jsonb_build_object('person', private.admin_person(r.user_id), 'via', r.via, 'detail', r.detail,
        'at', r.at) order by r.at desc nulls last)
    from (
      select distinct on (d2.user_id) d2.user_id, 'install' as via, d2.model as detail, d2.last_seen_at as at
      from private.devices d1 join private.devices d2 on d2.install_id = d1.install_id and d2.user_id <> d1.user_id
      where d1.user_id = p_user
      union all
      select * from (
        select distinct on (i2.user_id) i2.user_id, 'ip', host(i2.ip), i2.last_seen_at
        from private.ips i1 join private.ips i2 on i2.ip = i1.ip and i2.user_id <> i1.user_id
        where i1.user_id = p_user and i1.last_seen_at > now() - interval '30 days'
          and i2.last_seen_at > now() - interval '30 days'
        order by i2.user_id, i2.last_seen_at desc) ip
      union all
      select m.user_id, 'identity', m.kind || ' (' || m.state || ')', m.created_at
      from private.account_identities(p_user) a
      join private.identity_marks m on m.kind = a.kind and m.hash = a.hash
      where m.user_id <> p_user
    ) r), '[]');
end;
$$;

create function public.admin_add_note(p_actor text, p_user uuid, p_body text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_staff(p_actor, 'support');
  insert into private.staff_notes (user_id, author, body) values (p_user, lower(trim(p_actor)), trim(p_body));
  perform private.audit(p_actor, 'note.add', p_user);
end;
$$;

-- MARK: Holds

-- Puts a hold on an account or lifts it (null), with the reason. Lifting a ban takes an admin.
create function public.admin_set_hold(p_actor text, p_user uuid, p_state public.moderation_state, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current public.moderation_state;
begin
  perform private.require_staff(p_actor, 'moderator');
  perform private.require_reason(p_reason);
  select moderation into v_current from public.profiles where id = p_user;
  if not found then
    perform private.fail('not_found', 'no such account');
  end if;
  if v_current = 'banned' and p_state is distinct from 'banned' then
    perform private.require_staff(p_actor, 'admin');
  end if;
  perform set_config('drafft.moderation_actor', lower(trim(p_actor)), true);
  perform public.set_moderation(p_user, p_state, trim(p_reason));
  perform private.audit(p_actor, 'hold.set', p_user, null, p_reason,
    jsonb_build_object('from', v_current, 'to', p_state));
end;
$$;

-- Signs the account out of every device (the access token in hand still works until it expires, an hour
-- at most).
create function public.admin_revoke_sessions(p_actor text, p_user uuid, p_reason text)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count int;
begin
  perform private.require_staff(p_actor, 'moderator');
  perform private.require_reason(p_reason);
  delete from auth.sessions where user_id = p_user;
  get diagnostics v_count = row_count;
  perform private.audit(p_actor, 'sessions.revoke', p_user, null, p_reason, jsonb_build_object('count', v_count));
  return v_count;
end;
$$;

-- MARK: Verifications

-- Selfies to compare, accounts held for review, and selfies still owed. Oldest first.
create function public.admin_verifications(p_actor text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_staff(p_actor, 'support');
  return (
    with held as (
      select p.id, p.moderation,
             (select jsonb_build_object('note', l.note, 'actor', l.actor, 'at', l.created_at) from private.moderation_log l
              where l.user_id = p.id order by l.created_at desc limit 1) as last,
             (select jsonb_build_object('note', l.note, 'actor', l.actor, 'at', l.created_at) from private.moderation_log l
              where l.user_id = p.id and l.state is not null and l.note is distinct from 'selfie sent'
              order by l.created_at desc limit 1) as cause,
             (select max(c.created_at) from private.selfie_checks c where c.user_id = p.id) as selfie_at
      from public.profiles p where p.moderation in ('review', 'selfie')
    )
    select jsonb_build_object(
      'selfies', coalesce(jsonb_agg(jsonb_build_object('person', private.admin_person(h.id), 'selfieAt', h.selfie_at,
          'cause', h.cause, 'since', h.last -> 'at',
          'photos', (select coalesce(jsonb_agg(jsonb_build_object('key', coalesce(m.poster_key, m.key), 'status', m.status)
              order by m.position), '[]') from public.profile_media m where m.user_id = h.id))
          order by h.selfie_at) filter (where h.moderation = 'review' and h.selfie_at is not null), '[]'),
      'reviews', coalesce(jsonb_agg(jsonb_build_object('person', private.admin_person(h.id), 'cause', h.cause,
          'since', h.last -> 'at') order by h.last ->> 'at') filter (where h.moderation = 'review' and h.selfie_at is null), '[]'),
      'waitingSelfie', coalesce(jsonb_agg(jsonb_build_object('person', private.admin_person(h.id), 'cause', h.cause,
          'since', h.last -> 'at') order by h.last ->> 'at') filter (where h.moderation = 'selfie'), '[]'))
    from held h
  );
end;
$$;

-- The selfie paths of an account, to sign short-lived URLs. Logged.
create function public.admin_selfies(p_actor text, p_user uuid, p_reason text default 'verification')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_staff(p_actor, 'moderator');
  perform private.audit(p_actor, 'selfie.view', p_user, null, p_reason);
  return coalesce((select jsonb_agg(jsonb_build_object('path', c.path, 'createdAt', c.created_at) order by c.created_at desc)
    from private.selfie_checks c where c.user_id = p_user), '[]');
end;
$$;

-- MARK: Photos and flags

-- Profile media waiting for a person: second looks asked for first, then borderline ones (anything
-- still pending after 5 minutes: the automatic check has spoken).
create function public.admin_media_queue(p_actor text, p_limit int default 100)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_staff(p_actor, 'support');
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', m.id, 'person', private.admin_person(m.user_id), 'kind', m.kind,
        'key', m.key, 'posterKey', m.poster_key, 'width', m.width, 'height', m.height, 'createdAt', m.created_at,
        'reviewRequestedAt', m.review_requested_at, 'position', m.position,
        'labels', (select f.labels from public.media_flags f where f.key = m.key order by f.created_at desc limit 1),
        'account', private.admin_account_brief(m.user_id))
      order by m.review_requested_at nulls last, m.created_at)
    from (select * from public.profile_media
          where status = 'pending' and (review_requested_at is not null or created_at < now() - interval '5 minutes')
          order by review_requested_at nulls last, created_at
          limit least(greatest(p_limit, 1), 500)) m), '[]');
end;
$$;

create function public.admin_review_media(p_actor text, p_media uuid, p_approved boolean, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid;
begin
  perform private.require_staff(p_actor, 'moderator');
  select user_id into v_user from public.profile_media where id = p_media;
  perform public.review_media(p_media, p_approved);
  update public.media_flags set reviewed_at = now(), reviewed_by = lower(trim(p_actor))
    where key = (select key from public.profile_media where id = p_media) and reviewed_at is null;
  perform private.audit(p_actor, case when p_approved then 'media.approve' else 'media.reject' end, v_user,
    p_media::text, p_reason);
end;
$$;

-- Flagged photos and videos (chats and profiles). `open`: not looked at yet, oldest first (a queue);
-- otherwise everything, newest first.
create function public.admin_flags(p_actor text, p_open boolean default true, p_limit int default 60, p_offset int default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_staff(p_actor, 'moderator');
  return coalesce((
    select jsonb_agg(to_jsonb(f) - 'user_id' || jsonb_build_object('person', private.admin_person(f.user_id),
        'userFlags30d', (select count(*) from public.media_flags x
          where x.user_id = f.user_id and x.created_at > now() - interval '30 days'),
        'media', (select jsonb_build_object('id', m.id, 'status', m.status) from public.profile_media m where m.key = f.key),
        'account', private.admin_account_brief(f.user_id))
      order by case when p_open then f.created_at end, f.created_at desc)
    from (select * from public.media_flags where not p_open or reviewed_at is null
          order by case when p_open then created_at end, created_at desc
          limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)) f), '[]');
end;
$$;

-- Accounts flagged in the last 30 days, most first.
create function public.admin_flagged_users(p_actor text, p_limit int default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_staff(p_actor, 'moderator');
  return coalesce((
    select jsonb_agg(jsonb_build_object('person', private.admin_person(f.user_id), 'flags', f.flags,
        'rejected', f.rejected, 'inChats', f.in_chats, 'lastFlag', f.last_flag) order by f.flags desc, f.last_flag desc)
    from (select * from private.flagged_users where user_id is not null limit least(greatest(p_limit, 1), 200)) f), '[]');
end;
$$;

create function public.admin_resolve_flags(p_actor text, p_ids bigint[], p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_flag record;
begin
  perform private.require_staff(p_actor, 'moderator');
  for v_flag in
    update public.media_flags set reviewed_at = now(), reviewed_by = lower(trim(p_actor))
      where id = any (p_ids) and reviewed_at is null
      returning id, user_id
  loop
    perform private.audit(p_actor, 'flag.resolve', v_flag.user_id, v_flag.id::text, p_reason);
  end loop;
end;
$$;

-- MARK: Reports

create function public.admin_reports(p_actor text, p_open boolean default true, p_limit int default 60, p_offset int default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_staff(p_actor, 'support');
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', r.id, 'reason', r.reason, 'details', r.details, 'createdAt', r.created_at,
        'handledAt', r.handled_at, 'handledBy', r.handled_by, 'resolution', r.resolution,
        'reporter', private.admin_person(r.reporter), 'reported', private.admin_person(r.reported),
        'reportedCount30d', (select count(distinct x.reporter) from public.reports x
          where x.reported = r.reported and x.created_at > now() - interval '30 days'),
        'match', (select m.id from public.matches m
          where m.user_a = least(r.reporter, r.reported) and m.user_b = greatest(r.reporter, r.reported)))
      order by r.created_at desc)
    from (select * from public.reports where not p_open or handled_at is null
          order by created_at desc limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)) r), '[]');
end;
$$;

create function public.admin_resolve_report(p_actor text, p_report uuid, p_resolution text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reported uuid;
begin
  perform private.require_staff(p_actor, 'moderator');
  perform private.require_reason(p_resolution);
  update public.reports set handled_at = now(), handled_by = lower(trim(p_actor)), resolution = trim(p_resolution)
    where id = p_report and handled_at is null
    returning reported into v_reported;
  if not found then
    perform private.fail('not_found', 'no open report');
  end if;
  perform private.audit(p_actor, 'report.resolve', v_reported, p_report::text, p_resolution);
end;
$$;

-- MARK: Support

create function public.admin_support(
  p_actor text, p_open boolean default true, p_query text default '', p_limit int default 60, p_offset int default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_query text := nullif(trim(coalesce(p_query, '')), '');
begin
  perform private.require_staff(p_actor, 'support');
  return coalesce((
    select jsonb_agg(to_jsonb(s) - 'user_id' || jsonb_build_object('person', private.admin_person(s.user_id),
        'replies', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'author', m.author, 'body', m.body,
            'createdAt', m.created_at, 'sentAt', m.sent_at, 'error', m.error) order by m.created_at), '[]')
          from private.support_messages m where m.request_id = s.id))
      order by s.created_at desc)
    from (select * from private.support_requests
          where (not p_open or handled_at is null)
            and (v_query is null or reference ilike private.like_pattern(v_query) or email ilike private.like_pattern(v_query)
                 or message ilike private.like_pattern(v_query))
          order by created_at desc limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)) s), '[]');
end;
$$;

-- Replies from the team, written in sophros and emailed by db-events (`support.reply`), in the thread of
-- their request. Replies to that email reach SUPPORT_INBOX, for now.
create table private.support_messages (
  id bigint generated always as identity primary key,
  request_id bigint not null references private.support_requests (id) on delete cascade,
  author text not null,
  body text not null check (char_length(body) between 1 and 8000),
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  error text
);

create index support_messages_request_idx on private.support_messages (request_id, created_at);

-- Sends a reply to the person (queued: db-events emails it), and closes the request unless asked not to.
create function public.admin_reply_support(p_actor text, p_id bigint, p_body text, p_close boolean default true)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_message bigint;
  v_request private.support_requests;
begin
  perform private.require_staff(p_actor, 'support');
  if coalesce(trim(p_body), '') = '' then
    perform private.fail('empty_reply', 'write the reply first');
  end if;
  select * into v_request from private.support_requests where id = p_id;
  if not found then
    perform private.fail('not_found', 'no such request');
  end if;
  insert into private.support_messages (request_id, author, body)
    values (p_id, lower(trim(p_actor)), trim(p_body))
    returning id into v_message;
  perform private.emit('support.reply', jsonb_build_object('id', v_message));
  if p_close then
    update private.support_requests set handled_at = now(), handled_by = lower(trim(p_actor)) where id = p_id;
  end if;
  perform private.audit(p_actor, 'support.reply', v_request.user_id, v_request.reference, null,
    jsonb_build_object('closed', p_close));
end;
$$;

-- db-events: one reply and its request, to email it; then marked sent (or failed).
create function public.support_reply(p_id bigint)
returns table (reference text, email text, language text, topic text, message text, body text, author text, sent_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select r.reference, r.email, r.language, r.topic, r.message, m.body, m.author, m.sent_at
  from private.support_messages m join private.support_requests r on r.id = m.request_id
  where m.id = p_id;
$$;

create function public.support_reply_sent(p_id bigint, p_error text default null)
returns void
language sql
security definer
set search_path = ''
as $$
  update private.support_messages
    set sent_at = case when p_error is null then now() end, error = p_error
    where id = p_id;
$$;

revoke execute on function public.support_reply(bigint), public.support_reply_sent(bigint, text) from public, anon, authenticated;
grant execute on function public.support_reply(bigint), public.support_reply_sent(bigint, text) to service_role;

create function public.admin_set_support_handled(p_actor text, p_id bigint, p_handled boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid;
  v_reference text;
begin
  perform private.require_staff(p_actor, 'support');
  update private.support_requests
    set handled_at = case when p_handled then now() end, handled_by = case when p_handled then lower(trim(p_actor)) end
    where id = p_id
    returning user_id, reference into v_user, v_reference;
  if not found then
    perform private.fail('not_found', 'no such request');
  end if;
  perform private.audit(p_actor, case when p_handled then 'support.close' else 'support.reopen' end, v_user, v_reference);
end;
$$;

create function public.admin_data_requests(p_actor text, p_open boolean default true)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_staff(p_actor, 'support');
  return coalesce((
    select jsonb_agg(to_jsonb(d) - 'user_id' || jsonb_build_object('person', private.admin_person(d.user_id),
        'email', (select u.email from auth.users u where u.id = d.user_id)) order by d.created_at)
    from private.data_requests d where not p_open or d.fulfilled_at is null), '[]');
end;
$$;

create function public.admin_fulfil_data_request(p_actor text, p_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid;
begin
  perform private.require_staff(p_actor, 'support');
  update private.data_requests set fulfilled_at = now(), fulfilled_by = lower(trim(p_actor))
    where id = p_id and fulfilled_at is null
    returning user_id into v_user;
  if not found then
    perform private.fail('not_found', 'no open request');
  end if;
  perform private.audit(p_actor, 'data_request.fulfil', v_user, p_id::text);
end;
$$;

-- MARK: Conversations

-- Matches, newest first: everyone's, or one account's, narrowed by a name or email (either person),
-- status (active, ended), a report between them, chat photos flagged since they matched, or sessions.
-- The messages themselves are in Stream (one channel per match id); the dashboard logs each reading
-- through admin_log.
create function public.admin_matches(
  p_actor text, p_user uuid default null, p_query text default '', p_status text default 'all',
  p_reported boolean default false, p_flagged boolean default false, p_sessions boolean default false,
  p_limit int default 60, p_offset int default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_query text := nullif(trim(coalesce(p_query, '')), '');
begin
  perform private.require_staff(p_actor, 'moderator');
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', m.id, 'createdAt', m.created_at, 'endedAt', m.ended_at, 'endedBy', m.ended_by,
        'a', private.admin_person(m.user_a), 'b', private.admin_person(m.user_b),
        'sessions', m.sessions, 'reported', m.reported, 'chatFlags', m.chat_flags) order by m.created_at desc)
    from (
      select x.*,
             (select count(*) from public.sessions s where s.match_id = x.id) as sessions,
             exists (select 1 from public.reports r
               where (r.reporter = x.user_a and r.reported = x.user_b) or (r.reporter = x.user_b and r.reported = x.user_a)) as reported,
             (select count(*) from public.media_flags f
               where f.context = 'chat' and f.user_id in (x.user_a, x.user_b) and f.created_at >= x.created_at) as chat_flags
      from public.matches x
      where (p_user is null or p_user in (x.user_a, x.user_b))
        and (p_status <> 'active' or x.ended_at is null)
        and (p_status <> 'ended' or x.ended_at is not null)
        and (v_query is null or exists (
          select 1 from public.profiles p join auth.users u on u.id = p.id
          where p.id in (x.user_a, x.user_b)
            and (p.name ilike private.like_pattern(v_query) or u.email ilike private.like_pattern(v_query)
                 or p.id::text = lower(v_query))))
      order by x.created_at desc
    ) m
    where (not p_reported or m.reported) and (not p_flagged or m.chat_flags > 0) and (not p_sessions or m.sessions > 0)
    limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)), '[]');
end;
$$;

create function public.admin_match(p_actor text, p_match uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_staff(p_actor, 'moderator');
  return (
    select jsonb_build_object('id', m.id, 'createdAt', m.created_at, 'endedAt', m.ended_at, 'endedBy', m.ended_by,
      'a', private.admin_person(m.user_a), 'b', private.admin_person(m.user_b),
      'sessions', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'sport', s.sport_id, 'status', s.status,
          'options', s.options, 'chosenAt', s.chosen_at, 'proposer', s.proposer_id, 'title', s.title, 'note', s.note,
          'createdAt', s.created_at) order by s.created_at desc), '[]') from public.sessions s where s.match_id = m.id))
    from public.matches m where m.id = p_match);
end;
$$;

-- MARK: Audit

-- What the dashboard did outside this database, or read: a conversation, a deleted message.
create function public.admin_log(p_actor text, p_action text, p_user uuid, p_target text, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_action not in ('conversation.view', 'message.delete') then
    perform private.fail('invalid_action', 'unknown action');
  end if;
  perform private.require_staff(p_actor, 'moderator');
  perform private.require_reason(p_reason);
  perform private.audit(p_actor, p_action, p_user, p_target, p_reason);
end;
$$;

-- One account's trail (moderators), or everything (admins).
create function public.admin_audit(p_actor text, p_user uuid default null, p_limit int default 100, p_offset int default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_staff(p_actor, case when p_user is null then 'admin' else 'moderator' end);
  return coalesce((
    select jsonb_agg(to_jsonb(a) || jsonb_build_object('person', private.admin_person(a.user_id)) order by a.id desc)
    from (select * from private.admin_audit where p_user is null or user_id = p_user
          order by id desc limit least(greatest(p_limit, 1), 500) offset greatest(p_offset, 0)) a), '[]');
end;
$$;

-- MARK: Grants

do $$
declare
  v_fn regprocedure;
begin
  for v_fn in
    select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'admin\_%'
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', v_fn);
    execute format('grant execute on function %s to service_role', v_fn);
  end loop;
end;
$$;
