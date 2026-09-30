-- The terms and the consent to sensitive data, recorded on the server (before this migration the app kept
-- them only on the phone). Gender and the genders someone wants to see can reveal their sexual orientation,
-- lifestyle answers their health or beliefs (GDPR art. 9): drafft processes them on the member's explicit
-- consent, which it must be able to show (art. 7(1)). The app asks for it in its own step, apart from the terms.
--
-- public.accept_terms(p_version, p_sensitive_consent), signed in, for the caller only:
--   - records the terms: `terms_version` (the version the app showed, an ISO date `YYYY-MM-DD`) and
--     `terms_accepted_at`, now, on every call, even for the version already on record;
--   - true: records the consent, `sensitive_consent_at`, now;
--   - false or null: `sensitive_consent_required` when no consent is on record, onboarded or not (drafft
--     can't work without a gender, so there is no account without the consent). With a consent on record,
--     the terms alone are recorded and the consent stays as it was: false never withdraws it (withdrawing
--     is deleting the account);
--   - appends every accepted call to private.consent_events, the history the profile columns can't keep.
--   Errors: `unauthenticated`, `not_found` (no profile, or an account deleted and kept for safety),
--   `invalid_terms_version` (not a `YYYY-MM-DD` date, or older than the version on record),
--   `sensitive_consent_required`.
--
-- complete_onboarding() now also needs both (`terms_required`). Accounts onboarded before this migration have
-- neither and stay valid: nothing on the server blocks them; the app asks at its next open (terms_version
-- behind the version it ships, or sensitive_consent_at null) and calls accept_terms with the consent.
--
-- Lifestyle answers can be cleared on their own, from Edit profile. The owner reads the three columns
-- (profiles select); only accept_terms writes them (not in any profiles column grant).
--
-- migration-guard: allow destructive drop - the only truncate here is the trigger that forbids it

alter table public.profiles
  add column terms_version text check (terms_version ~ '^\d{4}-\d{2}-\d{2}$'),
  add column terms_accepted_at timestamptz,
  add column sensitive_consent_at timestamptz,
  add constraint profiles_terms_pair check ((terms_version is null) = (terms_accepted_at is null)),
  add constraint profiles_consent_after_terms check (sensitive_consent_at is null or terms_accepted_at is not null);

-- Every acceptance, in order: which version, whether that call gave the consent, when. Insert-only: the
-- triggers below refuse updates, truncates and direct deletes; rows go only with the profile (erased with it,
-- kept with it while the account is kept for safety). Part of the member's data export.
create table private.consent_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  terms_version text not null check (terms_version ~ '^\d{4}-\d{2}-\d{2}$'),
  sensitive_consent boolean not null,
  at timestamptz not null default now()
);

create index consent_events_user_idx on private.consent_events (user_id, at);

create function private.consent_events_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- The profile's ON DELETE CASCADE deletes from inside a trigger (depth 2 or more here); a DELETE on the
  -- table itself runs at depth 1.
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then
    return old;
  end if;
  raise exception 'the consent log is append-only' using errcode = 'P0001', hint = 'append_only';
end;
$$;

create trigger consent_events_append_only before update or delete on private.consent_events
  for each row execute function private.consent_events_append_only();
create trigger consent_events_no_truncate before truncate on private.consent_events
  for each statement execute function private.consent_events_append_only();

create function public.accept_terms(p_version text, p_sensitive_consent boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  v_version text := trim(p_version);
  v_current text;
  v_consent timestamptz;
begin
  if v_me is null then
    perform private.fail('unauthenticated', 'sign in first');
  end if;
  if v_version is null or v_version !~ '^\d{4}-\d{2}-\d{2}$' then
    perform private.fail('invalid_terms_version', 'the terms version must be a date, YYYY-MM-DD');
  end if;
  begin
    perform v_version::date;
  exception when datetime_field_overflow then
    perform private.fail('invalid_terms_version', 'the terms version must be a date, YYYY-MM-DD');
  end;
  select terms_version, sensitive_consent_at into v_current, v_consent
    from public.profiles where id = v_me and deleted_at is null for update;
  if not found then
    perform private.fail('not_found', 'profile not found');
  end if;
  -- ISO dates compare as text.
  if v_version < v_current then
    perform private.fail('invalid_terms_version', 'the terms version is older than the one accepted');
  end if;
  if v_consent is null and p_sensitive_consent is not true then
    perform private.fail('sensitive_consent_required', 'drafft needs your consent to use your gender');
  end if;
  update public.profiles
    set terms_version = v_version,
        terms_accepted_at = now(),
        sensitive_consent_at = case when p_sensitive_consent then now() else sensitive_consent_at end
    where id = v_me;
  insert into private.consent_events (user_id, terms_version, sensitive_consent)
    values (v_me, v_version, coalesce(p_sensitive_consent, false));
end;
$$;

revoke all on function public.accept_terms(text, boolean) from public, anon;
grant execute on function public.accept_terms(text, boolean) to authenticated;

-- 20260928000102, plus the terms and the consent (`terms_required`) once the sign-up steps are done, and
-- `unauthenticated` when signed out (it answered `not_found`).
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
  if v_me is null then
    perform private.fail('unauthenticated', 'sign in first');
  end if;
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
