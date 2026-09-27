-- The app's forms reach the team, and the person hears back:
--
-- - Support requests ("Get help", "A mistake? Contact us", locked verifications), signed in or not: the
--   support function stores them with a reference; db-events emails the person an acknowledgement and the
--   team a copy (SUPPORT_INBOX), until the dashboard reads private.support_requests.
-- - Data export requests (You > Your data): stored, the team is emailed.
-- - Reports (report_user, 20260924000003): the team is emailed; a report of someone underage, or reports
--   from 3 different people in 30 days, put the account in `review` for a person to look at.
-- - A photo approved after a second look the person asked for (request_media_review): they're emailed.
-- - A hold lifted (account.moderation, 20260927000004): they're emailed that they're back.

-- MARK: Support

create table private.support_requests (
  id bigint generated always as identity primary key,
  -- DR-XXXXXX, shown in the app and the acknowledgement.
  reference text not null unique,
  -- Null when sent signed out (a locked sign-up), or once the account is deleted.
  user_id uuid references public.profiles (id) on delete set null,
  email text not null check (char_length(email) between 3 and 320),
  language text not null default 'en' check (language in ('en', 'fr', 'es', 'de', 'it', 'pt', 'nl')),
  topic text not null check (char_length(topic) between 1 and 80),
  message text not null check (char_length(message) between 1 and 4000),
  -- What the app knew: its version, the hold on screen, the screen it came from.
  context jsonb not null default '{}' check (octet_length(context::text) <= 2000),
  created_at timestamptz not null default now(),
  handled_at timestamptz
);

create index support_requests_open_idx on private.support_requests (created_at) where handled_at is null;
create index support_requests_email_idx on private.support_requests (lower(email), created_at desc);
create index support_requests_user_idx on private.support_requests (user_id, created_at desc);

-- The support function (service role): checks the limits, stores, queues the emails. Returns the reference.
-- Limits: 5 an hour per account or address; 200 an hour for everything sent signed out.
create function public.create_support_request(
  p_user uuid, p_email text, p_language text, p_topic text, p_message text, p_context jsonb default '{}'
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reference text;
  v_id bigint;
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if (select count(*) from private.support_requests
      where created_at > now() - interval '1 hour'
        and ((p_user is not null and user_id = p_user) or lower(email) = lower(p_email))) >= 5
     or (p_user is null and (select count(*) from private.support_requests
      where user_id is null and created_at > now() - interval '1 hour') >= 200) then
    perform private.fail('too_many_requests', 'too many messages, try again later');
  end if;
  loop
    v_reference := 'DR-' || (select string_agg(substr(v_alphabet, 1 + (get_byte(b, i) % 32), 1), '')
      from extensions.gen_random_bytes(6) b, generate_series(0, 5) i);
    exit when not exists (select 1 from private.support_requests where reference = v_reference);
  end loop;
  insert into private.support_requests (reference, user_id, email, language, topic, message, context)
    values (v_reference, p_user, trim(p_email),
      case when p_language in ('en', 'fr', 'es', 'de', 'it', 'pt', 'nl') then p_language else 'en' end,
      left(trim(p_topic), 80), trim(p_message), coalesce(p_context, '{}'))
    returning id into v_id;
  perform private.emit('support.created', jsonb_build_object('id', v_id));
  return v_reference;
end;
$$;

-- db-events: one request, to email it.
create function public.support_request(p_id bigint)
returns table (reference text, user_id uuid, email text, language text, topic text, message text, context jsonb)
language sql
stable
security definer
set search_path = ''
as $$
  select reference, user_id, email, language, topic, message, context from private.support_requests where id = p_id;
$$;

-- MARK: Data export

create table private.data_requests (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null default 'export' check (kind in ('export')),
  created_at timestamptz not null default now(),
  fulfilled_at timestamptz
);

create index data_requests_open_idx on private.data_requests (created_at) where fulfilled_at is null;
create index data_requests_user_idx on private.data_requests (user_id);

-- You > Your data > Email me my export. One open request at a time: asking again returns it.
create function public.request_data_export()
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  v_at timestamptz;
  v_id bigint;
begin
  select created_at into v_at from private.data_requests
    where user_id = v_me and kind = 'export' and fulfilled_at is null
    order by created_at desc limit 1;
  if v_at is not null then
    return v_at;
  end if;
  insert into private.data_requests (user_id) values (v_me) returning id, created_at into v_id, v_at;
  perform private.emit('export.requested', jsonb_build_object('id', v_id, 'userId', v_me));
  return v_at;
end;
$$;

-- MARK: Reports

-- Every report reaches the team. Someone reported as underage, or reported by 3 different people in 30
-- days, is held for review at once: a person decides (a lone malicious report only costs a review).
create function private.on_report()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_note text;
begin
  perform private.emit('report.created', jsonb_build_object('id', new.id));
  if new.reason = 'underage' then
    v_note := 'reported as underage';
  elsif (select count(distinct reporter) from public.reports
         where reported = new.reported and created_at > now() - interval '30 days') >= 3 then
    v_note := 'reported by 3 people in 30 days';
  end if;
  if v_note is not null and exists (select 1 from public.profiles where id = new.reported and moderation is null) then
    perform public.set_moderation(new.reported, 'review', v_note);
  end if;
  return null;
end;
$$;

create trigger reports_events after insert on public.reports
  for each row execute function private.on_report();

-- db-events: one report, to email the team.
create function public.report_details(p_id uuid)
returns table (reporter uuid, reported uuid, reason public.report_reason, details text, reported_hold public.moderation_state)
language sql
stable
security definer
set search_path = ''
as $$
  select r.reporter, r.reported, r.reason, r.details, p.moderation
  from public.reports r left join public.profiles p on p.id = r.reported where r.id = p_id;
$$;

-- MARK: Second look at a photo

-- A photo refused, sent for a second look (request_media_review), then approved: the person is emailed.
create function private.on_media_reviewed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.review_requested_at is not null and new.status = 'approved' and old.status <> 'approved' then
    perform private.emit('media.approved_on_review', jsonb_build_object('mediaId', new.id, 'userId', new.user_id));
  end if;
  return null;
end;
$$;

create trigger profile_media_reviewed after update of status on public.profile_media
  for each row execute function private.on_media_reviewed();

-- The team's decision on a photo (the dashboard; editing status in Studio works too).
create function public.review_media(p_media uuid, p_approved boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.profile_media
    set status = case when p_approved then 'approved' else 'rejected' end::public.media_status,
        review_requested_at = null
    where id = p_media;
  if not found then
    perform private.fail('not_found', 'no such media');
  end if;
end;
$$;

-- MARK: Grants

revoke execute on function public.create_support_request(uuid, text, text, text, text, jsonb),
  public.support_request(bigint), public.report_details(uuid), public.review_media(uuid, boolean)
  from public, anon, authenticated;
grant execute on function public.create_support_request(uuid, text, text, text, text, jsonb),
  public.support_request(bigint), public.report_details(uuid), public.review_media(uuid, boolean)
  to service_role;
grant execute on function public.request_data_export() to authenticated;
