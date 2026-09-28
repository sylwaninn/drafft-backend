-- A person's decision on a photo (review_media, called by admin_review_media from the dashboard) now
-- leaves an outbox event, like Rekognition's does: `media.reviewed {mediaId, userId, status, secondLook, at}`.
-- db-events pushes a refusal to the owner (`photo_refused`, in their language, the same push as an
-- automatic refusal) and emails it when they had asked for that second look (request_media_review). An
-- approval needs nothing more: the app hears `media` on Realtime, and an approval on a second look is
-- already emailed (media.approved_on_review, 20260927000005).
--
-- Only a change is announced: confirming a photo that is already refused (a flag looked at in the
-- dashboard) sends nothing, Rekognition's refusal already did. `at` tells two decisions on the same photo
-- apart (refused, sent back, refused again), so each gets its email once.
-- Editing the status by hand in Studio stays silent, as before.

create or replace function public.review_media(p_media uuid, p_approved boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status public.media_status := case when p_approved then 'approved' else 'rejected' end;
  v_user uuid;
  v_before public.media_status;
  v_second_look boolean;
begin
  select user_id, status, review_requested_at is not null into v_user, v_before, v_second_look
    from public.profile_media where id = p_media
    for update;
  if not found then
    perform private.fail('not_found', 'no such media');
  end if;
  update public.profile_media set status = v_status, review_requested_at = null where id = p_media;
  if v_before <> v_status then
    perform private.emit('media.reviewed', jsonb_build_object(
      'mediaId', p_media, 'userId', v_user, 'status', v_status, 'secondLook', v_second_look,
      'at', extract(epoch from clock_timestamp())::bigint));
  end if;
end;
$$;

-- `create or replace` keeps the grants of 20260927000005 (service_role only); restated for clarity.
revoke execute on function public.review_media(uuid, boolean) from public, anon, authenticated;
grant execute on function public.review_media(uuid, boolean) to service_role;
