-- The terms and the consent to sensitive data, recorded on the server (until now the app kept them on the
-- phone). Gender and the genders someone wants to see can reveal their sexual orientation, lifestyle answers
-- their health or beliefs (GDPR art. 9): drafft processes them on the member's explicit consent, which it
-- must be able to show (art. 7(1)). The app asks for it in its own step, apart from the terms.
--
-- public.accept_terms(p_version, p_sensitive_consent), signed in, for the caller only:
--   - records the terms: `terms_version` (the version the app showed) and `terms_accepted_at`, now;
--   - true: records the consent, `sensitive_consent_at`, now;
--   - false: during onboarding, `sensitive_consent_required` (drafft can't work without a gender, so
--     there is no account without the consent); once onboarded, the terms alone are recorded and an
--     earlier consent stays as it was.
--   Errors: `unauthenticated`, `not_found` (no profile), `invalid_terms_version` (empty, or over 40 characters),
--   `sensitive_consent_required`. Calling it again (a new version of the terms) moves the dates to now.
--
-- complete_onboarding() now also needs both (`terms_required`). Accounts onboarded before this migration have
-- neither and stay valid: nothing on the server blocks them; the app asks at its next open (terms_version
-- behind the version it ships, or sensitive_consent_at null) and calls accept_terms.
--
-- Withdrawing the consent means deleting the account (delete-account): gender is required. Lifestyle
-- answers can be cleared on their own, from Edit profile. The owner reads the three columns (profiles
-- select); only accept_terms writes them (not in the column grants of 20260924000002).

alter table public.profiles
  add column terms_version text check (char_length(terms_version) between 1 and 40),
  add column terms_accepted_at timestamptz,
  add column sensitive_consent_at timestamptz;

create function public.accept_terms(p_version text, p_sensitive_consent boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  v_onboarded timestamptz;
begin
  if v_me is null then
    perform private.fail('unauthenticated', 'sign in first');
  end if;
  if coalesce(char_length(trim(p_version)), 0) not between 1 and 40 then
    perform private.fail('invalid_terms_version', 'the terms version is missing or too long');
  end if;
  select onboarded_at into v_onboarded from public.profiles where id = v_me for update;
  if not found then
    perform private.fail('not_found', 'profile not found');
  end if;
  if v_onboarded is null and p_sensitive_consent is not true then
    perform private.fail('sensitive_consent_required', 'drafft needs your consent to use your gender');
  end if;
  update public.profiles
    set terms_version = trim(p_version),
        terms_accepted_at = now(),
        sensitive_consent_at = case when p_sensitive_consent then now() else sensitive_consent_at end
    where id = v_me;
end;
$$;

revoke all on function public.accept_terms(text, boolean) from public, anon;
grant execute on function public.accept_terms(text, boolean) to authenticated;

-- 20260928000102, plus the terms and the consent (`terms_required`) once the sign-up steps are done.
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
  if p.terms_accepted_at is null or p.sensitive_consent_at is null then
    perform private.fail('terms_required', 'accept the terms and the use of your sensitive data first');
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
