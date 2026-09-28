-- sophros stays live: every change to a moderation queue sends a private Realtime broadcast on the
-- `staff:queues` topic. Only the sophros Worker listens, with the secret key (service role, which bypasses
-- RLS); no signed-in person or visitor can join or send on a staff topic.
-- The payload names the queue and nothing else: no id, no person, no content. sophros re-reads its own
-- data when it hears it. One event per statement, so a bulk update is one event, not thousands.

create function private.staff_queue_changed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform realtime.send(jsonb_build_object('queue', tg_argv[0]), 'queue', 'staff:queues', true);
  return null;
exception when others then
  -- Realtime is a nicety: never fail the write because of it.
  raise warning 'staff broadcast % failed: %', tg_argv[0], sqlerrm;
  return null;
end;
$$;

revoke all on function private.staff_queue_changed() from public, anon, authenticated;

create trigger staff_live_reports after insert or delete or update of handled_at on public.reports
  for each statement execute function private.staff_queue_changed('reports');

create trigger staff_live_photos after insert or delete or update of status, review_requested_at
  on public.profile_media
  for each statement execute function private.staff_queue_changed('photos');

create trigger staff_live_media after insert or delete on public.media_flags
  for each statement execute function private.staff_queue_changed('media');

create trigger staff_live_selfies after insert or delete on private.selfie_checks
  for each statement execute function private.staff_queue_changed('verifications');

create trigger staff_live_accounts after update of moderation on public.profiles
  for each statement execute function private.staff_queue_changed('accounts');

create trigger staff_live_support after insert or update or delete on private.support_requests
  for each statement execute function private.staff_queue_changed('support');

create trigger staff_live_support_messages after insert or update or delete on private.support_messages
  for each statement execute function private.staff_queue_changed('support');

-- Staff topics are closed to the app and to visitors, whatever other policy says.
create policy staff_topic_closed_receive on realtime.messages as restrictive for select to anon, authenticated
  using (realtime.topic() not like 'staff:%');

create policy staff_topic_closed_send on realtime.messages as restrictive for insert to anon, authenticated
  with check (realtime.topic() not like 'staff:%');
