-- sophros shows accounts kept after their owner deleted them (20260928000131):
--
-- - admin_users: `deleted_at` on each row, and a `deleted` filter;
-- - admin_person (every list and related account): `deletedAt`;
-- - admin_related_accounts: the previous account of someone who signed up again with the identity of a kept
--   one, and the later account from the kept one's side;
-- - admin_account_deletion: the record of a kept account (when, basis, reports and holds behind it, legal
--   basis), for its page. Read with the account (`user.view` is logged by admin_user), support and above.
-- The rest of admin_users and admin_related_accounts is unchanged from 20260928000092.

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
             or (char_length(v_digits) >= 4 and u.phone like '%' || v_digits || '%'))
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


create or replace function private.admin_person(p_user uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case when p_user is null then null else coalesce((
    select jsonb_build_object('id', p.id, 'name', p.name, 'moderation', p.moderation, 'deletedAt', p.deleted_at,
      'photo', (
      select coalesce(m.poster_key, m.key) from public.profile_media m
      where m.user_id = p.id order by m.status = 'approved' desc, m.position limit 1))
    from public.profiles p where p.id = p_user),
    jsonb_build_object('id', p_user, 'deleted', true)) end;
$$;

create or replace function private.admin_related_accounts(p_user uuid)
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
      union all
      -- An account deleted while reported or held, and the one signing up again with its identity.
      select l.deleted_user_id, 'previous account', l.via, l.created_at from private.account_links l where l.user_id = p_user
      union all
      select l.user_id, 'later account', l.via, l.created_at from private.account_links l where l.deleted_user_id = p_user
    ) r), '[]');
end;
$$;
create function public.admin_account_deletion(p_actor text, p_user uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_staff(p_actor, 'support');
  return (
    select jsonb_build_object('deletedAt', d.deleted_at, 'basis', d.basis, 'legalBasis', d.legal_basis,
      'moderation', d.refs -> 'moderation',
      'reports', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'reason', r.reason, 'createdAt', r.created_at,
          'handledAt', r.handled_at, 'resolution', r.resolution) order by r.created_at), '[]')
        from public.reports r where r.id in (select (jsonb_array_elements_text(d.refs -> 'reports'))::uuid)),
      'holds', (select coalesce(jsonb_agg(jsonb_build_object('state', l.state, 'note', l.note, 'createdAt', l.created_at)
          order by l.created_at), '[]')
        from private.moderation_log l where l.id in (select (jsonb_array_elements_text(d.refs -> 'holds'))::bigint)),
      'identities', d.identities)
    from private.account_deletions d where d.user_id = p_user);
end;
$$;

revoke execute on function public.admin_account_deletion(text, uuid) from public, anon, authenticated;
grant execute on function public.admin_account_deletion(text, uuid) to service_role;
