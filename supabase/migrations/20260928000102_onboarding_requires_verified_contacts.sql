-- Sign-up is email, then its code, then the phone number and its SMS code, then the profile: finishing it
-- now checks both on the server. Without a confirmed email, `email_unconfirmed`; without a confirmed phone
-- number, `phone_required`. Accounts already onboarded are not affected (they return early, as before).
create or replace function public.complete_onboarding()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  p public.profiles;
  u record;
begin
  select * into p from public.profiles where id = v_me for update;
  if p.id is null then
    perform private.fail('not_found', 'profile not found');
  end if;
  if p.onboarded_at is not null then
    return;
  end if;
  select email_confirmed_at, phone, phone_confirmed_at into u from auth.users where id = v_me;
  if u.email_confirmed_at is null then
    perform private.fail('email_unconfirmed', 'confirm your email first');
  end if;
  if u.phone_confirmed_at is null or coalesce(u.phone, '') = '' then
    perform private.fail('phone_required', 'verify your phone number first');
  end if;
  if char_length(trim(p.name)) = 0 then
    perform private.fail('name_required', 'name is required');
  end if;
  if p.birthdate is null or p.birthdate > current_date - interval '18 years' then
    perform private.fail('underage', 'you must be 18 or older');
  end if;
  if p.gender is null then
    perform private.fail('gender_required', 'gender is required');
  end if;
  if cardinality(p.sport_ids) = 0 then
    perform private.fail('sport_required', 'add at least one sport');
  end if;
  if not exists (select 1 from public.profile_media m where m.user_id = v_me and m.kind = 'photo') then
    perform private.fail('photo_required', 'add at least one photo');
  end if;
  update public.profiles set onboarded_at = now() where id = v_me;
end;
$$;
