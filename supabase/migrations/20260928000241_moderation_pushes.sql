-- db-events (service role), for the moderation pushes: whether the account's latest review came from a
-- selfie it sent (submit_selfie notes 'selfie sent'). Read from the log, not selfie_checks: a lifted hold
-- deletes the selfies (selfie.delete) while the push may still be on its way.
create function public.review_was_selfie(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select note = 'selfie sent' from private.moderation_log
     where user_id = p_user and state = 'review'
     order by id desc limit 1
  ), false);
$$;

revoke execute on function public.review_was_selfie(uuid) from public, anon, authenticated;
grant execute on function public.review_was_selfie(uuid) to service_role;
