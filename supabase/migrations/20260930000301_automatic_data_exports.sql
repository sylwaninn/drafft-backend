-- Data exports, sent automatically (they were prepared by hand from the team's email, 20260927000005). What
-- the app and the privacy policy promise: "You get a link by email, usually within 24 hours, valid for 7 days"
-- (one link per part when the export needs several).
--
-- You › Privacy & data › Export my data (request_data_export) queues `export.requested`, and db-events:
--   1. claims the request (export_begin: one build at a time, taken back after 15 minutes if it stopped);
--   2. without an email address on the account, tells the team and closes the request (export_closed,
--      `no_email`): nothing is built;
--   3. builds the export: data.json with what export_data() returns, the messages and reactions the person sent
--      (Stream) and their own photos, videos, voice intro and chat attachments (R2), zipped in parts that each
--      fit one Storage upload (EXPORT_MAX_BYTES), part 1 first with data.json;
--   4. stores each part in the private bucket `data-exports`, at <user id>/<request id>-<part>.zip, and records
--      them at once (export_stored), so they expire 7 days on whatever happens next; a request gone meanwhile
--      (the account erased) gets its parts deleted instead;
--   5. emails the person a signed link per part, valid 7 days, in their language;
--   6. marks the request fulfilled (export_ready).
-- `data-exports-expire` (pg_cron, hourly) queues `export.expired` for files past their 7 days: db-events deletes
-- them, then export_file_deleted records it. `data-exports-sweep` (daily) queues `export.sweep` for objects no
-- request refers to any more (a build that failed for good). delete-account deletes the account's folder (every
-- part) at once.
--
-- request_data_export() is unchanged: one open request at a time, asking again answers its date; a closed one
-- (`fulfilled_at` set with a `closed_reason`) no longer counts, so asking again after adding an email works. The
-- team still sees requests in sophros and can fulfil one by hand (admin_fulfil_data_request).

insert into storage.buckets (id, name, public, allowed_mime_types)
  values ('data-exports', 'data-exports', false, array['application/zip']);

alter table private.data_requests
  add column started_at timestamptz,
  -- The parts of the export, in order, recorded as soon as they are stored (at least one; a profile's files
  -- make a few at most), and when they expire.
  add column file_paths text[] check (cardinality(file_paths) between 1 and 100),
  add column expires_at timestamptz,
  add column file_deleted_at timestamptz,
  -- Done with, without an export: `fulfilled_at` is set too, with no files.
  add column closed_reason text check (closed_reason in ('no_email')),
  add constraint data_requests_files_expire check ((file_paths is null) = (expires_at is null)),
  add constraint data_requests_deleted_files check (file_deleted_at is null or file_paths is not null),
  add constraint data_requests_closed check (closed_reason is null or (fulfilled_at is not null and file_paths is null));

create index data_requests_expiring_idx on private.data_requests (expires_at)
  where file_paths is not null and file_deleted_at is null;

-- MARK: Building

-- db-events claims a request before building it: 'go' (claimed), 'busy' (another delivery is building it,
-- claimed less than 15 minutes ago), 'done' (fulfilled already) or 'gone' (the account was erased since).
create function public.export_begin(p_id bigint)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  r private.data_requests;
begin
  select * into r from private.data_requests where id = p_id for update;
  if not found then
    return 'gone';
  end if;
  if r.fulfilled_at is not null then
    return 'done';
  end if;
  if r.started_at > now() - interval '15 minutes' then
    return 'busy';
  end if;
  update private.data_requests set started_at = now() where id = p_id;
  return 'go';
end;
$$;

-- One account's data, as its owner may read it (GDPR art. 15 and 20). Other people appear by first name and id
-- only, as the app shows them. Left out: what protects someone else (the reports about this account and who made
-- them, the likes received, the team's notes, links to other accounts) and what is only the team's (the audit
-- log, who reviewed a photo). Messages and reactions come from Stream and files from R2: db-events adds them.
create function public.export_data(p_user uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with person as (select p.* from public.profiles p where p.id = p_user)
  select jsonb_build_object(
    'account', (select jsonb_build_object('id', u.id, 'email', u.email, 'phone', nullif(u.phone, ''),
        'createdAt', u.created_at, 'emailConfirmedAt', u.email_confirmed_at, 'phoneConfirmedAt', u.phone_confirmed_at,
        'lastSignInAt', u.last_sign_in_at,
        'signIns', (select coalesce(jsonb_agg(jsonb_build_object('provider', i.provider, 'email', i.email,
            'createdAt', i.created_at, 'lastSignInAt', i.last_sign_in_at) order by i.created_at), '[]')
          from auth.identities i where i.user_id = u.id))
      from auth.users u where u.id = p_user),
    -- The profile row as stored: identity, lifestyle, settings, notifications, language, consent, hold.
    'profile', (select to_jsonb(p) - 'voice_levels' - 'sport_ids' - 'photo_count' from person p),
    'sports', (select coalesce(jsonb_agg(jsonb_build_object('sport', s.sport_id, 'perWeek', s.per_week)
        order by s.position), '[]') from public.profile_sports s where s.user_id = p_user),
    'prompts', (select coalesce(jsonb_agg(jsonb_build_object('question', q.question, 'answer', q.answer)
        order by q.position), '[]') from public.profile_prompts q where q.user_id = p_user),
    'media', (select coalesce(jsonb_agg(jsonb_build_object('kind', m.kind, 'key', m.key, 'posterKey', m.poster_key,
        'status', m.status, 'position', m.position, 'createdAt', m.created_at) order by m.position), '[]')
      from public.profile_media m where m.user_id = p_user),
    'location', (select jsonb_build_object('lat', extensions.st_y(l.geo::extensions.geometry),
        'lng', extensions.st_x(l.geo::extensions.geometry), 'roundedTo', '0.01 degree', 'updatedAt', l.updated_at)
      from private.locations l where l.user_id = p_user),
    'wallet', (select to_jsonb(w) - 'user_id' from public.wallets w where w.user_id = p_user),
    'swipes', (select coalesce(jsonb_agg(jsonb_build_object('to', jsonb_build_object('id', s.target, 'name', t.name),
        'action', s.action, 'opener', s.opener, 'note', s.note, 'createdAt', s.created_at) order by s.created_at), '[]')
      from public.swipes s left join public.profiles t on t.id = s.target where s.swiper = p_user),
    'matches', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id,
        'with', jsonb_build_object('id', o.id, 'name', o.name), 'createdAt', m.created_at, 'endedAt', m.ended_at,
        'endedByYou', m.ended_by = p_user) order by m.created_at), '[]')
      from public.matches m
      left join public.profiles o on o.id = case when m.user_a = p_user then m.user_b else m.user_a end
      where p_user in (m.user_a, m.user_b)),
    'sessions', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'match', s.match_id, 'sport', s.sport_id,
        'title', s.title, 'note', s.note, 'options', s.options, 'chosenAt', s.chosen_at, 'status', s.status,
        'proposedByYou', s.proposer_id = p_user, 'createdAt', s.created_at, 'updatedAt', s.updated_at)
        order by s.created_at), '[]')
      from public.sessions s join public.matches m on m.id = s.match_id where p_user in (m.user_a, m.user_b)),
    'blocks', (select coalesce(jsonb_agg(jsonb_build_object('who', jsonb_build_object('id', b.blocked, 'name', o.name),
        'createdAt', b.created_at) order by b.created_at), '[]')
      from public.blocks b left join public.profiles o on o.id = b.blocked where b.blocker = p_user),
    'reportsMade', (select coalesce(jsonb_agg(jsonb_build_object('who', jsonb_build_object('id', r.reported, 'name', o.name),
        'reason', r.reason, 'details', r.details, 'createdAt', r.created_at, 'handledAt', r.handled_at)
        order by r.created_at), '[]')
      from public.reports r left join public.profiles o on o.id = r.reported where r.reporter = p_user),
    'holds', (select coalesce(jsonb_agg(jsonb_build_object('state', l.state, 'at', l.created_at) order by l.created_at), '[]')
      from private.moderation_log l where l.user_id = p_user),
    'selfies', (select coalesce(jsonb_agg(jsonb_build_object('sentAt', c.created_at) order by c.created_at), '[]')
      from private.selfie_checks c where c.user_id = p_user),
    'support', (select coalesce(jsonb_agg(jsonb_build_object('reference', r.reference, 'topic', r.topic,
        'message', r.message, 'email', r.email, 'context', r.context, 'createdAt', r.created_at,
        'replies', (select coalesce(jsonb_agg(jsonb_build_object('body', m.body, 'at', m.created_at) order by m.created_at), '[]')
          from private.support_messages m where m.request_id = r.id and m.sent_at is not null))
        order by r.created_at), '[]')
      from private.support_requests r
      where r.user_id = p_user or lower(r.email) = (select lower(u.email) from auth.users u where u.id = p_user)),
    'purchases', (select coalesce(jsonb_agg(jsonb_build_object('type', e.type, 'product', e.product_id,
        'at', e.event_at, 'effect', e.effect) order by e.event_at), '[]')
      from public.purchase_events e where e.user_id = p_user),
    'devices', (select coalesce(jsonb_agg(to_jsonb(d) - 'user_id' order by d.last_seen_at), '[]')
      from private.devices d where d.user_id = p_user),
    'ips', (select coalesce(jsonb_agg(to_jsonb(i) - 'user_id' order by i.last_seen_at), '[]')
      from private.ips i where i.user_id = p_user),
    'pushTokens', (select coalesce(jsonb_agg(jsonb_build_object('environment', t.environment, 'updatedAt', t.updated_at)), '[]')
      from public.push_tokens t where t.user_id = p_user),
    'deviceCheck', (select to_jsonb(c) - 'user_id' from private.device_checks c where c.user_id = p_user),
    'verificationTexts', (select coalesce(jsonb_agg(jsonb_build_object('phone', s.phone, 'ip', s.ip, 'sentAt', s.created_at,
        'approvedAt', s.approved_at, 'usedAt', s.used_at) order by s.created_at), '[]')
      from private.sms_sends s where s.user_id = p_user),
    'credits', (select coalesce(jsonb_agg(jsonb_build_object('product', c.product_id, 'kind', c.kind, 'quantity', c.quantity,
        'source', c.source, 'creditedAt', c.credited_at, 'refundedAt', c.refunded_at) order by c.created_at), '[]')
      from private.purchase_credits c where c.user_id = p_user),
    -- The automatic checks of the person's own photos and videos (profile and chat), and a person's review.
    'mediaChecks', (select coalesce(jsonb_agg(jsonb_build_object('key', f.key, 'context', f.context, 'verdict', f.verdict,
        'labels', f.labels, 'at', f.created_at, 'reviewedAt', f.reviewed_at) order by f.created_at), '[]')
      from public.media_flags f where f.user_id = p_user),
    'consents', (select coalesce(jsonb_agg(jsonb_build_object('termsVersion', e.terms_version,
        'sensitiveDataConsent', e.sensitive_consent, 'at', e.at) order by e.at, e.id), '[]')
      from private.consent_events e where e.user_id = p_user),
    'dataRequests', (select coalesce(jsonb_agg(jsonb_build_object('createdAt', d.created_at, 'fulfilledAt', d.fulfilled_at,
        'closedReason', d.closed_reason) order by d.created_at), '[]') from private.data_requests d where d.user_id = p_user)
  )
  where exists (select 1 from person);
$$;

-- The parts, stored: recorded at once, so they expire 7 days on even if the email never goes. Only the request's
-- own paths (<user id>/<request id>-<part>.zip). False when the request is gone (the account erased meanwhile):
-- db-events then deletes the parts itself.
create function public.export_stored(p_id bigint, p_paths text[])
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  r private.data_requests;
begin
  select * into r from private.data_requests where id = p_id for update;
  if not found then
    return false;
  end if;
  if coalesce(cardinality(p_paths), 0) = 0 or exists (select 1 from unnest(p_paths) x
      where x !~ ('^' || r.user_id || '/' || r.id || '-[0-9]{1,3}\.zip$')) then
    perform private.fail('invalid_paths', 'export parts outside the request''s own paths');
  end if;
  update private.data_requests set file_paths = p_paths, expires_at = now() + interval '7 days', file_deleted_at = null
    where id = p_id;
  return true;
end;
$$;

-- Emailed: fulfilled. False when there is nothing stored to fulfil it with (gone, or files deleted already).
create function public.export_ready(p_id bigint)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  update private.data_requests
    set fulfilled_at = coalesce(fulfilled_at, now()), fulfilled_by = coalesce(fulfilled_by, 'automatic'), started_at = null
    where id = p_id and file_paths is not null and file_deleted_at is null;
  return found;
end;
$$;

-- No export possible (no email address to send it to): done with, and said why. The team was told.
create function public.export_closed(p_id bigint, p_reason text)
returns void
language sql
security definer
set search_path = ''
as $$
  update private.data_requests
    set fulfilled_at = now(), fulfilled_by = 'automatic', closed_reason = p_reason, started_at = null
    where id = p_id and fulfilled_at is null;
$$;

-- MARK: Expiring

create function public.export_file_deleted(p_id bigint)
returns void
language sql
security definer
set search_path = ''
as $$
  update private.data_requests set file_deleted_at = now() where id = p_id and file_deleted_at is null;
$$;

-- Hourly: files past their 7 days, one event each (again after a day when the deletion failed).
create function private.queue_export_expiries()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
  v_count int := 0;
begin
  for v_id in
    select d.id from private.data_requests d
    where d.file_paths is not null and d.file_deleted_at is null and d.expires_at < now()
      and not exists (select 1 from private.outbox o
        where o.event = 'export.expired' and o.payload ->> 'id' = d.id::text
          and (o.created_at > now() - interval '1 day' or (o.delivered_at is null and o.failed_at is null
            and o.discarded_at is null)))
    order by d.expires_at limit 500
  loop
    perform private.emit('export.expired', jsonb_build_object('id', v_id));
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- db-events: the files of one request (every part), to delete them.
create function public.export_files(p_id bigint)
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select file_paths from private.data_requests where id = p_id and file_deleted_at is null;
$$;

-- Daily: objects of the bucket that no request refers to any more (a build that failed for good, or stopped
-- after storing some parts), a day old at least, so a build under way keeps its own. Queued in one event, 1000
-- at most a day. Returns how many.
create function private.queue_export_sweep()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_paths text[];
begin
  if exists (select 1 from private.outbox where event = 'export.sweep'
             and delivered_at is null and failed_at is null and discarded_at is null) then
    return 0;
  end if;
  select coalesce(array_agg(o.name order by o.name), '{}') into v_paths from (
    select o.name from storage.objects o
    where o.bucket_id = 'data-exports' and o.created_at < now() - interval '1 day'
      and not exists (select 1 from private.data_requests d
                      where d.file_deleted_at is null and o.name = any (d.file_paths))
    order by o.created_at limit 1000) o;
  if cardinality(v_paths) = 0 then
    return 0;
  end if;
  perform private.emit('export.sweep', jsonb_build_object('paths', to_jsonb(v_paths)));
  return cardinality(v_paths);
end;
$$;

update private.outbox_policies set providers = '{stream,r2,resend}' where event = 'export.requested';
insert into private.outbox_policies (event, retry_budget, expires_after, push_ttl, providers, erasure) values
  ('export.expired', '24 hours', null, null, '{}', true),
  ('export.sweep', '24 hours', null, null, '{}', true);

revoke all on function private.queue_export_expiries(), private.queue_export_sweep() from public, anon, authenticated;
revoke execute on function public.export_begin(bigint), public.export_data(uuid), public.export_stored(bigint, text[]),
  public.export_ready(bigint), public.export_closed(bigint, text), public.export_file_deleted(bigint),
  public.export_files(bigint) from public, anon, authenticated;
grant execute on function public.export_begin(bigint), public.export_data(uuid), public.export_stored(bigint, text[]),
  public.export_ready(bigint), public.export_closed(bigint, text), public.export_file_deleted(bigint),
  public.export_files(bigint) to service_role;

select cron.schedule('data-exports-expire', '12 * * * *', 'select private.queue_export_expiries()');
select cron.schedule('data-exports-sweep', '42 4 * * *', 'select private.queue_export_sweep()');
