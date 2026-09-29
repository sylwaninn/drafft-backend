-- The terms and the sensitive-data consent (20260930000001): recorded by accept_terms for the caller only,
-- required to finish onboarding, and never blocking an account onboarded before.
begin;
create extension if not exists pgtap with schema extensions;
select plan(17);

-- Everything onboarding asks for except the terms: confirmed email and phone, name, age, gender, a sport
-- and a photo.
create function pg_temp.person(p_email text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id, email_confirmed_at, phone, phone_confirmed_at)
  values (v_id, p_email, 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000', now(),
    '336' || lpad((floor(random() * 1e8))::bigint::text, 8, '0'), now());
  update public.profiles set name = split_part(p_email, '@', 1), birthdate = '1995-05-05', gender = 'woman'
    where id = v_id;
  insert into public.profile_sports (user_id, sport_id, per_week, position) values (v_id, 'running', 3, 0);
  insert into public.profile_media (user_id, key, position, width, height)
    values (v_id, 'u/' || v_id || '/photos/a.jpg', 0, 100, 100);
  return v_id;
end $$;

create function pg_temp.login(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

grant execute on all functions in schema pg_temp to authenticated;

create temp table ids as select
  pg_temp.person('ana@test.dev') as ana,
  pg_temp.person('ben@test.dev') as ben,
  pg_temp.person('old@test.dev') as old;
grant select on ids to authenticated;

-- An account onboarded before the terms were recorded.
update public.profiles set onboarded_at = now() - interval '30 days' where id = (select old from ids);

select ok(has_function_privilege('authenticated', 'public.accept_terms(text, boolean)', 'execute'),
  'signed-in people can accept');
select ok(not has_function_privilege('anon', 'public.accept_terms(text, boolean)', 'execute'), 'signed-out callers cannot');

set local role authenticated;

-- MARK: Onboarding

select pg_temp.login((select ana from ids));
select throws_ok('select public.complete_onboarding()', 'P0001',
  'accept the terms and the use of your sensitive data first', 'onboarding needs the terms: terms_required');
select throws_ok($$select public.accept_terms('2026-09', false)$$, 'P0001',
  'drafft needs your consent to use your gender', 'no consent during onboarding: sensitive_consent_required');
select throws_ok($$select public.accept_terms('2026-09', null)$$, 'P0001',
  'drafft needs your consent to use your gender', 'nor an unanswered one');
select throws_ok($$select public.accept_terms('  ', true)$$, 'P0001',
  'the terms version is missing or too long', 'an empty version: invalid_terms_version');
select throws_ok(format('select public.accept_terms(%L, true)', repeat('v', 41)), 'P0001',
  'the terms version is missing or too long', 'over 40 characters too');
select is((select terms_accepted_at from public.profiles where id = (select ana from ids)), null::timestamptz,
  'a refused call records nothing');

select lives_ok($$select public.accept_terms(' 2026-09 ', true)$$, 'terms and consent accepted');
select is((select jsonb_build_object('version', terms_version, 'terms', terms_accepted_at = now(),
    'consent', sensitive_consent_at = now()) from public.profiles where id = (select ana from ids)),
  '{"version": "2026-09", "terms": true, "consent": true}'::jsonb, 'the version and both dates are recorded');
select lives_ok('select public.complete_onboarding()', 'then onboarding finishes');
select isnt((select onboarded_at from public.profiles where id = (select ana from ids)), null::timestamptz,
  'the account is onboarded');

-- Only the caller's own row, and never through PATCH /profiles.
select is((select terms_accepted_at from public.profiles where id = (select ben from ids)), null::timestamptz,
  'another account is untouched');
select throws_ok($$update public.profiles set sensitive_consent_at = now()$$, '42501', null,
  'the columns cannot be written directly');

-- MARK: Accounts onboarded before

select pg_temp.login((select old from ids));
select lives_ok('select public.complete_onboarding()', 'an account onboarded before stays valid');
select lives_ok($$select public.accept_terms('2026-09', false)$$,
  'once onboarded, the terms can be recorded without the consent');
select is((select jsonb_build_object('version', terms_version, 'consent', sensitive_consent_at)
    from public.profiles where id = (select old from ids)),
  '{"version": "2026-09", "consent": null}'::jsonb, 'the terms alone are recorded');

reset role;
select * from finish();
rollback;
