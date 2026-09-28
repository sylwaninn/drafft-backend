-- sophros' audit log (20260927000007), completed:
--
-- - private.admin_audit refuses TRUNCATE too, not only UPDATE and DELETE row by row. The table's owner
--   can still disable the triggers: that is the limit of what the database can enforce on itself.
-- - Reading lists of personal data is logged like opening an account: a search in admin_users
--   (`user.search`, with the query), admin_related (`user.related`) and admin_data_requests
--   (`data_requests.view`). These functions are no longer `stable`, since they now write.
-- - admin_user gives chat photo flags and the list of matches to moderators and admins only, like
--   admin_flags and admin_matches. Support gets their counts instead (`hidden`), and no `matches` key.
--   Everything else is unchanged. Opening an account still writes one row (`user.view`): the related
--   accounts it includes come from a private function, not from the logged admin_related.
--
-- migration-guard: allow destructive drop - the only truncate here is the trigger that forbids it

-- MARK: Audit log

create trigger admin_audit_no_truncate before truncate on private.admin_audit
  for each statement execute function private.audit_append_only();

-- MARK: Accounts

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
  v_result jsonb;
begin
  perform private.require_staff(p_actor, 'support');
  v_result := coalesce((
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
  perform private.audit(p_actor, 'user.search', null, null, null, jsonb_build_object(
    'query', v_query, 'filter', p_filter, 'offset', greatest(p_offset, 0), 'results', jsonb_array_length(v_result)));
  return v_result;
end;
$$;

create function private.admin_related_accounts(p_user uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
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

revoke all on function private.admin_related_accounts(uuid) from public;

create or replace function public.admin_related(p_actor text, p_user uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_staff(p_actor, 'support');
  perform private.audit(p_actor, 'user.related', p_user);
  return private.admin_related_accounts(p_user);
end;
$$;

create or replace function public.admin_user(p_actor text, p_user uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
  v_moderator boolean := private.staff_rank(
    (select role from private.staff where email = lower(trim(p_actor)) and disabled_at is null)) >= 2;
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
      from (select * from public.media_flags where user_id = p.id and (v_moderator or context <> 'chat')
            order by created_at desc limit 100) f),
    'support', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'reference', s.reference, 'topic', s.topic,
        'createdAt', s.created_at, 'handledAt', s.handled_at) order by s.created_at desc), '[]')
      from private.support_requests s where s.user_id = p.id or lower(s.email) = lower(u.email)),
    'dataRequests', (select coalesce(jsonb_agg(to_jsonb(d) - 'user_id' order by d.created_at desc), '[]')
      from private.data_requests d where d.user_id = p.id),
    'notes', (select coalesce(jsonb_agg(to_jsonb(n) - 'user_id' order by n.created_at desc), '[]')
      from private.staff_notes n where n.user_id = p.id),
    'related', private.admin_related_accounts(p.id)
  )
  into v_result
  from public.profiles p join auth.users u on u.id = p.id
  where p.id = p_user;

  if v_result is null then
    perform private.fail('not_found', 'no such account');
  end if;
  -- Support sees how many, not what: chat photos and matches are the moderators' (admin_flags, admin_matches).
  if not v_moderator then
    v_result := v_result - 'matches' || jsonb_build_object('hidden', jsonb_build_object(
      'chatFlags', (select count(*) from public.media_flags where user_id = p_user and context = 'chat'),
      'matches', (select count(*) from public.matches where p_user in (user_a, user_b))));
  end if;
  perform private.audit(p_actor, 'user.view', p_user);
  return v_result;
end;
$$;

-- MARK: Data requests

create or replace function public.admin_data_requests(p_actor text, p_open boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_staff(p_actor, 'support');
  perform private.audit(p_actor, 'data_requests.view', null, null, null, jsonb_build_object('open', p_open));
  return coalesce((
    select jsonb_agg(to_jsonb(d) - 'user_id' || jsonb_build_object('person', private.admin_person(d.user_id),
        'email', (select u.email from auth.users u where u.id = d.user_id)) order by d.created_at)
    from private.data_requests d where not p_open or d.fulfilled_at is null), '[]');
end;
$$;
