-- Moderation decisions come with their reasons (DSA art. 17), and reading a conversation needs one.
--
-- 1. Statement of reasons. When a person on the team refuses a photo, removes a message, puts an account on
--    hold (review, selfie) or bans it, the member is told what was decided and why: a reason category from a
--    fixed list (private.reason_categories, matching the terms' community guidelines) and, optionally, a note
--    written by the team for them. The decision is stored (private.moderation_decisions) and queued
--    (`moderation.decision`): db-events emails it in the person's language, with the rule it applies, how to
--    contest it (the in-app help center, or a reply: Reply-To SUPPORT_INBOX, reviewed by someone else), and
--    pushes it when no push says it already (a removed message, a review, a ban; a refused photo and a selfie
--    request have theirs). A removed message is told once Stream shows it removed.
--    sophros passes `p_category` and `p_details` to admin_set_hold, admin_review_media, admin_decide_photo,
--    admin_close_report, admin_decide_flags and admin_log ('message.delete'). Both default to null so the
--    sophros deployed before this keeps working: a decision without a category is told as `other`.
-- 2. Reading a conversation (admin_log 'conversation.view'; removing a message in it too) needs a reason written
--    by the person (not the old default "opened in sophros") and a basis: a report between the two members, a
--    help request from either in the last 90 days or still open, or either account on hold or banned
--    (admin_conversation_access says which). Without one, only an admin may read it, with `p_override`, which
--    the audit log records. Viewing selfies (admin_selfies) needs a reason too: no default any more.
-- Automatic decisions (the photo check, holds from reports or a device) keep their own messages.
--
-- migration-guard: allow destructive drop - admin_* functions only, recreated at once with extra defaulted parameters

-- MARK: Reasons

create table private.reason_categories (
  id text primary key,
  -- Where the rule is in the terms of use.
  terms_section text not null
);

insert into private.reason_categories (id, terms_section) values
  ('harassment', 'community_guidelines'),
  ('hate', 'community_guidelines'),
  ('sexual_content', 'community_guidelines'),
  ('violence_illegal', 'community_guidelines'),
  ('underage', 'to_use_drafft'),
  ('impersonation', 'community_guidelines'),
  ('scam_commercial', 'community_guidelines'),
  ('privacy', 'community_guidelines'),
  ('fake_account', 'to_use_drafft'),
  ('evasion', 'community_guidelines'),
  ('photo_guidelines', 'community_guidelines'),
  ('identity_check', 'moderation_and_sanctions'),
  ('other', 'terms_of_use');

create table private.moderation_decisions (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null check (kind in ('photo_refused', 'message_deleted', 'account_review', 'account_selfie', 'account_banned')),
  category text not null references private.reason_categories (id),
  -- Written by the team for the member, sent as written.
  details text check (char_length(details) <= 1000),
  -- The photo (media id) or the message (`<match id>/<message id>`).
  target text check (char_length(target) <= 200),
  actor text not null,
  created_at timestamptz not null default now()
);

create index moderation_decisions_user_idx on private.moderation_decisions (user_id, created_at desc);
create index moderation_decisions_category_idx on private.moderation_decisions (category);

-- sophros: the categories to choose from.
create function public.admin_reason_categories(p_actor text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_staff(p_actor, 'support');
  return (select jsonb_agg(jsonb_build_object('id', id, 'termsSection', terms_section) order by id)
    from private.reason_categories);
end;
$$;

-- Records a decision about a member and queues its statement. No category (a sophros from before): `other`.
create function private.record_decision(
  p_actor text, p_user uuid, p_kind text, p_category text, p_details text, p_target text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
  v_category text := coalesce(nullif(trim(p_category), ''), 'other');
begin
  if not exists (select 1 from private.reason_categories where id = v_category) then
    perform private.fail('invalid_category', 'unknown reason category');
  end if;
  insert into private.moderation_decisions (user_id, kind, category, details, target, actor)
    values (p_user, p_kind, v_category, left(nullif(trim(p_details), ''), 1000), p_target, lower(trim(p_actor)))
    returning id into v_id;
  perform private.emit('moderation.decision', jsonb_build_object('id', v_id));
end;
$$;

-- db-events: one decision, with what the statement needs.
create function public.moderation_decision(p_id bigint)
returns table (user_id uuid, kind text, category text, details text, target text, language text, created_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select d.user_id, d.kind, d.category, d.details, d.target, p.language, d.created_at
  from private.moderation_decisions d join public.profiles p on p.id = d.user_id
  where d.id = p_id;
$$;

insert into private.outbox_policies (event, retry_budget, expires_after, push_ttl, providers)
  values ('moderation.decision', '24 hours', null, '6 hours', '{resend,apns,stream}');

-- MARK: Holds

-- 20260927000007, plus the member's reason when a hold is put or turned into a ban.
drop function public.admin_set_hold(text, uuid, public.moderation_state, text);
create function public.admin_set_hold(
  p_actor text, p_user uuid, p_state public.moderation_state, p_reason text,
  p_category text default null, p_details text default null
)
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
    jsonb_build_object('from', v_current, 'to', p_state, 'category', p_category));
  if p_state is not null and p_state is distinct from v_current then
    perform private.record_decision(p_actor, p_user, 'account_' || case p_state when 'banned' then 'banned'
      when 'selfie' then 'selfie' else 'review' end, p_category, p_details, null);
  end if;
end;
$$;

-- MARK: Photos

-- 20260927000007, plus the member's reason when a person refuses the photo.
drop function public.admin_review_media(text, uuid, boolean, text);
create function public.admin_review_media(
  p_actor text, p_media uuid, p_approved boolean, p_reason text default null,
  p_category text default null, p_details text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid;
  v_before public.media_status;
begin
  perform private.require_staff(p_actor, 'moderator');
  select user_id, status into v_user, v_before from public.profile_media where id = p_media;
  perform public.review_media(p_media, p_approved);
  update public.media_flags set reviewed_at = now(), reviewed_by = lower(trim(p_actor))
    where key = (select key from public.profile_media where id = p_media) and reviewed_at is null;
  perform private.audit(p_actor, case when p_approved then 'media.approve' else 'media.reject' end, v_user,
    p_media::text, p_reason, jsonb_build_object('category', p_category));
  if not p_approved and v_before is distinct from 'rejected' then
    perform private.record_decision(p_actor, v_user, 'photo_refused', p_category, p_details, p_media::text);
  end if;
end;
$$;

-- 20260928000031, plus the reason: of the refusal, and of the hold when there is one.
drop function public.admin_decide_photo(text, uuid, text, public.moderation_state, text);
create function public.admin_decide_photo(
  p_actor text, p_media uuid, p_reason text default null, p_hold public.moderation_state default null,
  p_hold_reason text default null, p_category text default null, p_details text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_media record;
  v_flag record;
begin
  perform private.require_staff(p_actor, 'moderator');
  select id, user_id, key, status into v_media from public.profile_media where id = p_media for update;
  if not found then
    perform private.fail('not_found', 'no such media');
  end if;
  if v_media.status = 'pending' then
    perform public.review_media(p_media, false);
    perform private.audit(p_actor, 'media.reject', v_media.user_id, p_media::text, p_reason,
      jsonb_build_object('category', p_category));
    perform private.record_decision(p_actor, v_media.user_id, 'photo_refused', p_category, p_details, p_media::text);
  elsif v_media.status = 'rejected'
    and exists (select 1 from public.media_flags where key = v_media.key and reviewed_at is null) then
    -- The automatic check's refusal, confirmed: the member was told then.
    null;
  else
    perform private.fail('not_found', 'the photo was already decided on');
  end if;
  for v_flag in
    update public.media_flags set reviewed_at = now(), reviewed_by = lower(trim(p_actor))
      where key = v_media.key and reviewed_at is null
      returning id, user_id
  loop
    perform private.audit(p_actor, 'flag.resolve', v_flag.user_id, v_flag.id::text, p_reason);
  end loop;
  if p_hold is not null then
    perform public.admin_set_hold(p_actor, v_media.user_id, p_hold, coalesce(nullif(trim(p_hold_reason), ''), p_reason),
      p_category, p_details);
  end if;
end;
$$;

-- MARK: Reports and flags

-- 20260928000031, plus the member's reason for the hold.
drop function public.admin_close_report(text, uuid, text, public.moderation_state);
create function public.admin_close_report(
  p_actor text, p_report uuid, p_resolution text, p_hold public.moderation_state default null,
  p_category text default null, p_details text default null
)
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
  select reported into v_reported from public.reports where id = p_report and handled_at is null for update;
  if not found then
    perform private.fail('not_found', 'no open report');
  end if;
  update public.reports set handled_at = now(), handled_by = lower(trim(p_actor)), resolution = trim(p_resolution)
    where id = p_report;
  perform private.audit(p_actor, 'report.resolve', v_reported, p_report::text, p_resolution,
    jsonb_build_object('hold', p_hold));
  if p_hold is not null then
    perform public.admin_set_hold(p_actor, v_reported, p_hold, 'report: ' || trim(p_resolution), p_category, p_details);
  end if;
end;
$$;

drop function public.admin_decide_flags(text, bigint[], text, public.moderation_state, text);
create function public.admin_decide_flags(
  p_actor text, p_ids bigint[], p_reason text default null, p_hold public.moderation_state default null,
  p_hold_reason text default null, p_category text default null, p_details text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_open int;
  v_orphans int;
  v_users uuid[];
  v_flag record;
begin
  perform private.require_staff(p_actor, 'moderator');
  select count(*), count(*) filter (where f.user_id is null), array_agg(distinct f.user_id) filter (where f.user_id is not null)
    into v_open, v_orphans, v_users
    from (select id, user_id from public.media_flags where id = any (p_ids) and reviewed_at is null for update) f;
  if v_open = 0 then
    perform private.fail('not_found', 'no open flag');
  end if;
  if p_hold is not null then
    if v_orphans > 0 or coalesce(cardinality(v_users), 0) <> 1 then
      perform private.fail('one_account', 'the flags don''t belong to one account');
    end if;
    perform public.admin_set_hold(p_actor, v_users[1], p_hold, coalesce(nullif(trim(p_hold_reason), ''), p_reason),
      p_category, p_details);
  end if;
  for v_flag in
    update public.media_flags set reviewed_at = now(), reviewed_by = lower(trim(p_actor))
      where id = any (p_ids) and reviewed_at is null
      returning id, user_id
  loop
    perform private.audit(p_actor, 'flag.resolve', v_flag.user_id, v_flag.id::text, p_reason);
  end loop;
end;
$$;

-- MARK: Conversations

-- Why the team may read a match's conversation: a report between the two, a help request from either (open,
-- or from the last 90 days), either account on hold or banned. Empty: no reason on record.
create function private.conversation_basis(p_match uuid)
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select array_remove(array[
    case when exists (select 1 from public.reports r
      where (r.reporter = m.user_a and r.reported = m.user_b) or (r.reporter = m.user_b and r.reported = m.user_a))
      then 'report' end,
    case when exists (select 1 from private.support_requests s
      where s.user_id in (m.user_a, m.user_b) and (s.handled_at is null or s.created_at > now() - interval '90 days'))
      then 'support' end,
    case when exists (select 1 from public.profiles p where p.id in (m.user_a, m.user_b) and p.moderation is not null)
      then 'hold' end], null)
  from public.matches m where m.id = p_match;
$$;

-- sophros, before offering to open a conversation: its basis, and whether this person may override it.
create function public.admin_conversation_access(p_actor text, p_match uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_staff(p_actor, 'moderator');
  return jsonb_build_object(
    'basis', to_jsonb(coalesce(private.conversation_basis(p_match), '{}')),
    'canOverride', private.staff_rank((select role from private.staff
      where email = lower(trim(p_actor)) and disabled_at is null)) >= 3);
end;
$$;

-- What sophros does outside this database or reads, logged (20260927000007): reading a conversation, removing a
-- message. Both need a reason written by the person and a basis (private.conversation_basis), or an admin's
-- override. `p_target`: the match id, or `<match id>/<message id>` for a message. A removed message is told to
-- its author (`p_user`), with `p_category` and `p_details`.
drop function public.admin_log(text, text, uuid, text, text);
create function public.admin_log(
  p_actor text, p_action text, p_user uuid, p_target text, p_reason text,
  p_override boolean default false, p_category text default null, p_details text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_match uuid;
  v_basis text[];
begin
  if p_action not in ('conversation.view', 'message.delete') then
    perform private.fail('invalid_action', 'unknown action');
  end if;
  perform private.require_staff(p_actor, 'moderator');
  perform private.require_reason(p_reason);
  if lower(trim(p_reason)) = 'opened in sophros' then
    perform private.fail('reason_required', 'say why you read this conversation');
  end if;
  begin
    v_match := split_part(p_target, '/', 1)::uuid;
  exception when invalid_text_representation then
    perform private.fail('not_found', 'no such conversation');
  end;
  v_basis := private.conversation_basis(v_match);
  if v_basis is null then
    perform private.fail('not_found', 'no such conversation');
  end if;
  if cardinality(v_basis) = 0 then
    if not coalesce(p_override, false) then
      perform private.fail('no_basis', 'no report, help request or hold concerns this conversation');
    end if;
    perform private.require_staff(p_actor, 'admin');
  end if;
  perform private.audit(p_actor, p_action, p_user, p_target, p_reason,
    jsonb_build_object('basis', to_jsonb(v_basis), 'override', cardinality(v_basis) = 0, 'category', p_category));
  if p_action = 'message.delete' and p_user is not null then
    perform private.record_decision(p_actor, p_user, 'message_deleted', p_category, p_details, p_target);
  end if;
end;
$$;

-- MARK: Selfies

-- 20260927000007, the reason required (it defaulted to 'verification').
drop function public.admin_selfies(text, uuid, text);
create function public.admin_selfies(p_actor text, p_user uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_staff(p_actor, 'moderator');
  perform private.require_reason(p_reason);
  perform private.audit(p_actor, 'selfie.view', p_user, null, p_reason);
  return coalesce((select jsonb_agg(jsonb_build_object('path', c.path, 'createdAt', c.created_at) order by c.created_at desc)
    from private.selfie_checks c where c.user_id = p_user), '[]');
end;
$$;

-- MARK: Grants and retention

revoke all on function private.record_decision(text, uuid, text, text, text, text), private.conversation_basis(uuid)
  from public, anon, authenticated;
do $$
declare
  v_fn regprocedure;
begin
  for v_fn in
    select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('admin_reason_categories', 'admin_set_hold', 'admin_review_media',
      'admin_decide_photo', 'admin_close_report', 'admin_decide_flags', 'admin_conversation_access', 'admin_log',
      'admin_selfies', 'moderation_decision')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', v_fn);
    execute format('grant execute on function %s to service_role', v_fn);
  end loop;
end;
$$;

-- Like the moderation log: a year, three about a banned account; with the account when it's erased.
select cron.schedule('moderation-decisions-cleanup', '29 3 * * *', $$
  delete from private.moderation_decisions d
    where d.created_at < now() - case when exists (select 1 from public.profiles p where p.id = d.user_id and p.moderation = 'banned')
                                      then interval '3 years' else interval '1 year' end;
$$);
