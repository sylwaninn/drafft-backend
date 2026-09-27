-- sophros decisions made of several changes (close a report and hold its account, close a flag and ban
-- the sender, refuse a photo and hold its account) now happen in one call each: one transaction, so
-- either every change lands or none does. Before, the dashboard chained admin_* calls: a refused ban
-- still closed the flag ("account banned"), and a hold still landed on a report someone had just closed.
--
-- Each function locks what it decides on and refuses a decision already taken (not_found), so two
-- people deciding at once can't both apply theirs. Holds go through admin_set_hold: same role checks
-- (moderator, admin to lift a ban) and same audit as a hold set on its own.
--
-- admin_resolve_report, admin_resolve_flags and admin_review_media stay as they are, for the sophros
-- deployed before this one.

-- Closes an open report with its resolution, then holds the reported account (`p_hold`, optional).
create function public.admin_close_report(
  p_actor text, p_report uuid, p_resolution text, p_hold public.moderation_state default null
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
    perform public.admin_set_hold(p_actor, v_reported, p_hold, 'report: ' || trim(p_resolution));
  end if;
end;
$$;

-- Closes flags still open, and holds their account first (`p_hold`, optional, with `p_hold_reason`, or
-- `p_reason` when none). Refused when none of them is open any more, or, with a hold, when they belong
-- to more than one account or to a deleted one.
create function public.admin_decide_flags(
  p_actor text, p_ids bigint[], p_reason text default null, p_hold public.moderation_state default null,
  p_hold_reason text default null
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
    perform public.admin_set_hold(p_actor, v_users[1], p_hold, coalesce(nullif(trim(p_hold_reason), ''), p_reason));
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

-- Refuses a profile photo and holds its account (`p_hold`, optional, with `p_hold_reason`, or `p_reason`
-- when none). A photo waiting for a person is refused, which closes its flags; one the automatic check
-- already refused keeps its refusal and has its open flags closed. Refused when it's neither any more
-- (approved, or already decided by someone else).
create function public.admin_decide_photo(
  p_actor text, p_media uuid, p_reason text default null, p_hold public.moderation_state default null,
  p_hold_reason text default null
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
    perform private.audit(p_actor, 'media.reject', v_media.user_id, p_media::text, p_reason);
  elsif v_media.status = 'rejected'
    and exists (select 1 from public.media_flags where key = v_media.key and reviewed_at is null) then
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
    perform public.admin_set_hold(p_actor, v_media.user_id, p_hold, coalesce(nullif(trim(p_hold_reason), ''), p_reason));
  end if;
end;
$$;

revoke execute on function
  public.admin_close_report(text, uuid, text, public.moderation_state),
  public.admin_decide_flags(text, bigint[], text, public.moderation_state, text),
  public.admin_decide_photo(text, uuid, text, public.moderation_state, text)
  from public, anon, authenticated;
grant execute on function
  public.admin_close_report(text, uuid, text, public.moderation_state),
  public.admin_decide_flags(text, bigint[], text, public.moderation_state, text),
  public.admin_decide_photo(text, uuid, text, public.moderation_state, text)
  to service_role;
