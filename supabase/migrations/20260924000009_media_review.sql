-- Second review: the owner of a refused photo can ask a person to look at it. It goes back to
-- `pending` (still invisible to others) and joins the review queue.

alter table public.profile_media add column review_requested_at timestamptz;

create index profile_media_review_queue_idx on public.profile_media (review_requested_at)
  where status = 'pending' and review_requested_at is not null;

create function public.request_media_review(p_media uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.profile_media
    set status = 'pending', review_requested_at = now()
    where id = p_media and user_id = (select auth.uid()) and status = 'rejected';
  if not found then
    perform private.fail('not_reviewable', 'only your refused photos can be sent for review');
  end if;
end;
$$;

grant execute on function public.request_media_review(uuid) to authenticated;
