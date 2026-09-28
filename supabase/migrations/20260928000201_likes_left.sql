-- Likes left today, as swipe() counts them: the app shows "12 of 20 likes left" from the server instead of
-- counting on the device (a like from another device, or one that aged out of the 24 hours, is never missed).
--
-- { "unlimited": true } with drafft tempo; otherwise { "unlimited": false, "limit": 20, "left": n,
-- "nextAt": when the oldest like of the window stops counting (null when none counts) }.
-- The limit (20 likes in any 24 hours, super likes and passes aside) is swipe()'s (20260928000041).

create function public.likes_left()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  v_used int;
  v_oldest timestamptz;
begin
  if v_me is null then
    perform private.fail('unauthenticated', 'sign in first');
  end if;
  if private.is_premium(v_me) then
    return jsonb_build_object('unlimited', true);
  end if;
  select count(*), min(created_at) into v_used, v_oldest
  from public.swipes
  where swiper = v_me and action = 'like' and created_at > now() - interval '24 hours';
  return jsonb_build_object(
    'unlimited', false,
    'limit', 20,
    'left', greatest(0, 20 - v_used),
    'nextAt', v_oldest + interval '24 hours');
end;
$$;

revoke all on function public.likes_left() from public, anon;
grant execute on function public.likes_left() to authenticated;
