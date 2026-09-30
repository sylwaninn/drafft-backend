-- Moderation decisions come with their reasons (DSA art. 17), and reading a conversation needs one.
--
-- 1. Statement of reasons. When a person on the team refuses a photo, removes a message, puts an account on
--    hold (review, selfie) or bans it, the member is told what was decided and why: a reason category from a
--    fixed list (private.reason_categories), the section of the terms of use it falls under, with a link to it
--    (`terms_anchor`: getdrafft.com/terms#community, #eligibility, #moderation, or the page itself), and,
--    optionally, a note written by the team for them. The decision is stored (private.moderation_decisions) and
--    queued (`moderation.decision`): db-events emails it in the person's language with how to contest it (the
--    in-app help center, or a reply: Reply-To SUPPORT_INBOX, reviewed by someone else), and pushes it when no
--    push says it already (a removed message, a review, a ban; a refused photo and a selfie request have theirs).
--    A removed message is told once Stream shows it removed. A selfie asked again while one is already due
--    (the state stays `selfie`) is a statement too when it comes with a category, pushed as a selfie request.
--    sophros passes `p_category` and `p_details` to admin_set_hold, admin_review_media, admin_decide_photo,
--    admin_close_report, admin_decide_flags and admin_log ('message.delete'). Checked once, at the start: an
--    unknown category fails with `invalid_category`, a decision that sends a statement without one with
--    `category_required`, a note over 1,000 characters with `details_too_long`; either way nothing applies. The
--    audit log records the category. A sophros from before this migration (no category) can no longer decide.
-- 2. Reading a conversation (admin_log 'conversation.view'; removing a message in it too) needs a reason written
--    by the person (not the old default "opened in sophros") and a basis: a report between the two members, a
--    help request from either in the last 90 days or still open, or either account on hold or banned, unless
--    the reader put that hold themself (admin_conversation_access says which). Without one, only an admin may
--    read it, with `p_override` and why (`p_override_basis`: a legal request or members' safety), which the
--    audit log records. Viewing selfies (admin_selfies) needs a reason too: no default any more. A sophros from
--    before this migration (the "opened in sophros" default) can no longer open conversations: it ships first.
-- Automatic decisions (the photo check, holds from a device or a link to a banned account) keep their own
-- messages.
--
-- migration-guard: allow destructive drop - admin_* functions only, recreated at once with extra defaulted parameters

-- MARK: Reasons

create table private.reason_categories (
  id text primary key,
  -- The section of the terms of use (its anchor on getdrafft.com/terms); null: the terms as a whole.
  terms_anchor text check (terms_anchor in ('eligibility', 'community', 'moderation'))
);

insert into private.reason_categories (id, terms_anchor) values
  ('harassment', 'community'),
  ('hate', 'community'),
  ('sexual_content', 'community'),
  ('violence_illegal', 'community'),
  ('underage', 'eligibility'),
  ('impersonation', 'community'),
  ('scam_commercial', 'community'),
  ('privacy', 'community'),
  ('fake_account', 'eligibility'),
  ('evasion', 'community'),
  ('photo_guidelines', 'community'),
  ('identity_check', 'moderation'),
  ('other', null);

-- No foreign key to the profile: a banned account's decisions outlive it, like its moderation log
-- (20260930000201); private.on_profile_erased deletes any other account's.
create table private.moderation_decisions (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  kind text not null check (kind in ('photo_refused', 'message_deleted', 'account_review', 'account_selfie', 'account_banned')),
  category text not null references private.reason_categories (id),
  -- Written by the team for the member, sent as written.
  details text check (char_length(details) between 1 and 1000),
  -- The photo (media id) or the message (`<match id>/<message id>`).
  target text check (char_length(target) <= 200),
  actor text not null,
  created_at timestamptz not null default now(),
  constraint moderation_decisions_photo check (kind <> 'photo_refused' or target is not null),
  constraint moderation_decisions_message check (kind <> 'message_deleted'
    or target ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[^/]+$')
);

create index moderation_decisions_user_idx on private.moderation_decisions (user_id, created_at desc);
create index moderation_decisions_created_idx on private.moderation_decisions (created_at);
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
  return (select jsonb_agg(jsonb_build_object('id', id, 'termsAnchor', terms_anchor) order by id)
    from private.reason_categories);
end;
$$;

-- The category sophros sent, checked once, at the start of each admin_* function: null when none was given,
-- `invalid_category` when it isn't one of the list.
create function private.reason_category(p_category text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_category text := nullif(lower(trim(p_category)), '');
begin
  if v_category is not null and not exists (select 1 from private.reason_categories where id = v_category) then
    perform private.fail('invalid_category', 'unknown reason category');
  end if;
  return v_category;
end;
$$;

-- The team's note for the member, sent as written: never cut.
create function private.decision_details(p_details text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
begin
  if char_length(trim(p_details)) > 1000 then
    perform private.fail('details_too_long', 'the note for the member is over 1000 characters');
  end if;
  return nullif(trim(p_details), '');
end;
$$;

-- Records a decision about a member and queues its statement: a statement always says why
-- (`category_required`). `p_repeat`: the same hold asked again (a selfie), which no state change pushes.
create function private.record_decision(
  p_actor text, p_user uuid, p_kind text, p_category text, p_details text, p_target text,
  p_repeat boolean default false
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
begin
  if p_category is null then
    perform private.fail('category_required', 'choose the reason the member will read');
  end if;
  insert into private.moderation_decisions (user_id, kind, category, details, target, actor)
    values (p_user, p_kind, private.reason_category(p_category), private.decision_details(p_details), p_target,
      lower(trim(p_actor)))
    returning id into v_id;
  perform private.emit('moderation.decision', jsonb_build_object('id', v_id)
    || case when p_repeat then jsonb_build_object('repeat', true) else '{}' end);
end;
$$;

-- db-events: one decision, with what the statement needs.
create function public.moderation_decision(p_id bigint)
returns table (user_id uuid, kind text, category text, terms_anchor text, details text, target text, language text,
  created_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select d.user_id, d.kind, d.category, c.terms_anchor, d.details, d.target, p.language, d.created_at
  from private.moderation_decisions d
  join public.profiles p on p.id = d.user_id
  join private.reason_categories c on c.id = d.category
  where d.id = p_id;
$$;

insert into private.outbox_policies (event, retry_budget, expires_after, push_ttl, providers)
  values ('moderation.decision', '24 hours', null, '6 hours', '{resend,apns,stream}');

-- MARK: Holds

-- 20260927000007, plus the member's reason when a hold is put or turned into a ban, and when a selfie is asked
-- again with one (sophros's "Ask again": the state stays, the member gets the new reason and note). The same
-- state again without a category, or another hold again, states nothing.
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
  v_category text := private.reason_category(p_category);
  v_details text := private.decision_details(p_details);
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
    jsonb_build_object('from', v_current, 'to', p_state, 'category', v_category));
  if p_state is not null and p_state is distinct from v_current then
    perform private.record_decision(p_actor, p_user, 'account_' || case p_state when 'banned' then 'banned'
      when 'selfie' then 'selfie' else 'review' end, v_category, v_details, null);
  elsif p_state = 'selfie' and v_current = 'selfie' and v_category is not null then
    perform private.record_decision(p_actor, p_user, 'account_selfie', v_category, v_details, null, true);
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
  v_category text := private.reason_category(p_category);
  v_details text := private.decision_details(p_details);
begin
  perform private.require_staff(p_actor, 'moderator');
  select user_id, status into v_user, v_before from public.profile_media where id = p_media;
  perform public.review_media(p_media, p_approved);
  update public.media_flags set reviewed_at = now(), reviewed_by = lower(trim(p_actor))
    where key = (select key from public.profile_media where id = p_media) and reviewed_at is null;
  perform private.audit(p_actor, case when p_approved then 'media.approve' else 'media.reject' end, v_user,
    p_media::text, p_reason, jsonb_build_object('category', v_category));
  if not p_approved and v_before is distinct from 'rejected' then
    perform private.record_decision(p_actor, v_user, 'photo_refused', v_category, v_details, p_media::text);
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
  v_category text := private.reason_category(p_category);
  v_details text := private.decision_details(p_details);
begin
  perform private.require_staff(p_actor, 'moderator');
  select id, user_id, key, status into v_media from public.profile_media where id = p_media for update;
  if not found then
    perform private.fail('not_found', 'no such media');
  end if;
  if v_media.status = 'pending' then
    perform public.review_media(p_media, false);
    perform private.audit(p_actor, 'media.reject', v_media.user_id, p_media::text, p_reason,
      jsonb_build_object('category', v_category));
    perform private.record_decision(p_actor, v_media.user_id, 'photo_refused', v_category, v_details, p_media::text);
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
      v_category, v_details);
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
  v_category text := private.reason_category(p_category);
  v_details text := private.decision_details(p_details);
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
    jsonb_build_object('hold', p_hold, 'category', v_category));
  if p_hold is not null then
    perform public.admin_set_hold(p_actor, v_reported, p_hold, 'report: ' || trim(p_resolution), v_category, v_details);
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
  v_category text := private.reason_category(p_category);
  v_details text := private.decision_details(p_details);
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
      v_category, v_details);
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

-- Why `p_actor` may read a match's conversation: a report between the two, a help request from either (open, or
-- from the last 90 days), either account on hold or banned. A hold counts only when someone else put it (its
-- latest change in the moderation log): a moderator can't open their own way in. Empty: no reason on record;
-- null: no such match.
create function private.conversation_basis(p_match uuid, p_actor text)
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
    case when exists (select 1 from public.profiles p where p.id in (m.user_a, m.user_b) and p.moderation is not null
        and (select l.actor from private.moderation_log l where l.user_id = p.id
             order by l.created_at desc, l.id desc limit 1) is distinct from lower(trim(p_actor)))
      then 'hold' end], null)
  from public.matches m where m.id = p_match;
$$;

-- sophros, before offering to open a conversation: its basis, and whether this person may override it.
-- `not_found`: no such match.
create function public.admin_conversation_access(p_actor text, p_match uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_basis text[];
begin
  perform private.require_staff(p_actor, 'moderator');
  v_basis := private.conversation_basis(p_match, p_actor);
  if v_basis is null then
    perform private.fail('not_found', 'no such conversation');
  end if;
  return jsonb_build_object(
    'basis', to_jsonb(v_basis),
    'canOverride', private.staff_rank((select role from private.staff
      where email = lower(trim(p_actor)) and disabled_at is null)) >= private.staff_rank('admin'));
end;
$$;

-- What sophros does outside this database or reads, logged (20260927000007): reading a conversation, removing a
-- message. Both need a reason written by the person and a basis (private.conversation_basis), or an admin's
-- override, which says why (`p_override_basis`: 'legal_request' or 'member_safety'). `p_target`: the match id,
-- or `<match id>/<message id>` for a message, whose author (`p_user`, one of the two members) is told, with
-- `p_category` (required) and `p_details`.
drop function public.admin_log(text, text, uuid, text, text);
create function public.admin_log(
  p_actor text, p_action text, p_user uuid, p_target text, p_reason text,
  p_override boolean default false, p_category text default null, p_details text default null,
  p_override_basis text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_match uuid;
  v_basis text[];
  v_category text := private.reason_category(p_category);
  v_details text := private.decision_details(p_details);
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
  if p_action = 'message.delete' then
    if p_target !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[^/]+$' then
      perform private.fail('invalid_target', 'a message is <match id>/<message id>');
    end if;
    if p_user is null or not exists (select 1 from public.matches where id = v_match and p_user in (user_a, user_b)) then
      perform private.fail('invalid_target', 'the author must be one of the two members');
    end if;
    if v_category is null then
      perform private.fail('category_required', 'choose the reason the member will read');
    end if;
  end if;
  v_basis := private.conversation_basis(v_match, p_actor);
  if v_basis is null then
    perform private.fail('not_found', 'no such conversation');
  end if;
  if cardinality(v_basis) = 0 then
    if not coalesce(p_override, false) then
      perform private.fail('no_basis', 'no report, help request or hold concerns this conversation');
    end if;
    perform private.require_staff(p_actor, 'admin');
    if p_override_basis is null or p_override_basis not in ('legal_request', 'member_safety') then
      perform private.fail('override_basis_required', 'an override is for a legal request or members'' safety');
    end if;
  end if;
  perform private.audit(p_actor, p_action, p_user, p_target, p_reason,
    jsonb_build_object('basis', to_jsonb(v_basis), 'override', cardinality(v_basis) = 0,
      'overrideBasis', case when cardinality(v_basis) = 0 then p_override_basis end, 'category', v_category));
  if p_action = 'message.delete' then
    perform private.record_decision(p_actor, p_user, 'message_deleted', v_category, v_details, p_target);
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

-- MARK: Data export

-- 20260930000301, plus the decisions about the member.
create or replace function public.export_data(p_user uuid)
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
    -- The team's decisions about them, as their statements of reasons said them (who decided stays out).
    'decisions', (select coalesce(jsonb_agg(jsonb_build_object('kind', d.kind, 'category', d.category,
        'note', d.details, 'at', d.created_at) order by d.created_at), '[]')
      from private.moderation_decisions d where d.user_id = p_user),
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

-- MARK: Grants and retention

revoke all on function private.record_decision(text, uuid, text, text, text, text, boolean),
  private.conversation_basis(uuid, text), private.reason_category(text), private.decision_details(text)
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

-- 20260930000201, plus the decisions: they outlive a banned account, like its moderation log.
create or replace function private.on_profile_erased()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.moderation = 'banned' then
    return null;
  end if;
  delete from private.moderation_log where user_id = old.id;
  delete from private.staff_notes where user_id = old.id;
  delete from private.account_links where old.id in (user_id, deleted_user_id);
  delete from private.moderation_decisions where user_id = old.id;
  update public.media_flags set user_id = null where user_id = old.id;
  return null;
end;
$$;

-- Like the moderation log: a year, three about a banned account (private.retention_period, 20260930000101).
select cron.schedule('moderation-decisions-cleanup', '29 3 * * *', $$
  delete from private.moderation_decisions
    where created_at < now() - private.retention_period('moderation')
      and created_at < now() - private.moderation_retention(user_id);
$$);
