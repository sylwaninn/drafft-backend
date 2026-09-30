-- The terms and the sensitive-data consent (20260930000001): recorded by accept_terms for the caller only,
-- logged in private.consent_events, required to finish onboarding, and never blocking an account onboarded
-- before.
begin;
create extension if not exists pgtap with schema extensions;
select plan(47);

-- Everything onboarding asks for except the terms: confirmed email and phone, name, age, gender, a sport
-- and an approved photo.
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
  insert into public.profile_media (user_id, key, position, width, height, status)
    values (v_id, 'u/' || v_id || '/photos/a.jpg', 0, 100, 100, 'approved');
  return v_id;
end $$;

create function pg_temp.login(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

-- The error code a call fails with (private.fail puts it in the hint), or null when it succeeds.
create function pg_temp.hint(p_sql text) returns text language plpgsql as $$
declare
  v_hint text;
begin
  execute p_sql;
  return null;
exception when others then
  get stacked diagnostics v_hint = pg_exception_hint;
  return v_hint;
end $$;

grant execute on all functions in schema pg_temp to authenticated;

create temp table ids as select
  pg_temp.person('ana@test.dev') as ana,
  pg_temp.person('ben@test.dev') as ben,
  pg_temp.person('old@test.dev') as old,
  pg_temp.person('kept@test.dev') as kept,
  pg_temp.person('con@test.dev') as con;
grant select on ids to authenticated;

-- Accounts onboarded before the terms were recorded: one without any consent, one with an earlier consent.
update public.profiles set onboarded_at = now() - interval '30 days' where id in (select old from ids);
update public.profiles set onboarded_at = now() - interval '30 days', terms_version = '2026-01-01',
    terms_accepted_at = '2026-01-01', sensitive_consent_at = '2026-01-01'
  where id = (select con from ids);
-- An account deleted and kept for safety.
update public.profiles set onboarded_at = now() - interval '30 days', deleted_at = now()
  where id = (select kept from ids);

select ok(has_function_privilege('authenticated', 'public.accept_terms(text, boolean)', 'execute'),
  'signed-in people can accept');
select ok(not has_function_privilege('anon', 'public.accept_terms(text, boolean)', 'execute'), 'signed-out callers cannot');
select ok(not has_column_privilege('authenticated', 'public.profiles', c, p),
    format('%s on profiles.%s is not granted', p, c))
  from unnest(array['terms_version', 'terms_accepted_at', 'sensitive_consent_at']) c,
    unnest(array['update', 'insert']) p;

set local role authenticated;

-- MARK: Signed out

select set_config('request.jwt.claims', '{"role": "authenticated"}', true);
select is(pg_temp.hint($$select public.accept_terms('2026-09-29', true)$$), 'unauthenticated',
  'accept_terms signed out: unauthenticated');
select is(pg_temp.hint('select public.complete_onboarding()'), 'unauthenticated',
  'complete_onboarding signed out: unauthenticated');

-- MARK: Onboarding

select pg_temp.login((select ana from ids));
select is(pg_temp.hint('select public.complete_onboarding()'), 'terms_required', 'onboarding needs the terms');
select is(pg_temp.hint($$select public.accept_terms('2026-09-29', false)$$), 'sensitive_consent_required',
  'no consent during onboarding: sensitive_consent_required');
select is(pg_temp.hint($$select public.accept_terms('2026-09-29', null)$$), 'sensitive_consent_required',
  'nor an unanswered one');
select is(pg_temp.hint(format('select public.accept_terms(%L, true)', v)), 'invalid_terms_version',
    format('version %s: invalid_terms_version', coalesce(v, 'null')))
  from unnest(array[null, '  ', '2026-09', '29/09/2026', '2026-02-30', '2026-13-01', repeat('9', 41)]) v;
select throws_ok($$select public.accept_terms('2026-09', true)$$, 'P0001',
  'the terms version must be a date, YYYY-MM-DD', 'with a message for the logs');
select is((select terms_accepted_at from public.profiles where id = (select ana from ids)), null::timestamptz,
  'a refused call records nothing');

select lives_ok($$select public.accept_terms(' 2026-09-29 ', true)$$, 'terms and consent accepted');
select is((select jsonb_build_object('version', terms_version, 'terms', terms_accepted_at = now(),
    'consent', sensitive_consent_at = now()) from public.profiles where id = (select ana from ids)),
  '{"version": "2026-09-29", "terms": true, "consent": true}'::jsonb, 'the version, trimmed, and both dates are recorded');
select lives_ok('select public.complete_onboarding()', 'then onboarding finishes');
select isnt((select onboarded_at from public.profiles where id = (select ana from ids)), null::timestamptz,
  'the account is onboarded');
select is(pg_temp.hint($$select public.accept_terms('2026-09-28', true)$$), 'invalid_terms_version',
  'an older version than the one on record: invalid_terms_version');
select lives_ok($$select public.accept_terms('2026-09-29', false)$$, 'the same version again');

-- Only the caller's own row, and never through PATCH /profiles.
select throws_ok($$update public.profiles set sensitive_consent_at = now()$$, '42501', null,
  'the consent cannot be written directly');
select throws_ok($$update public.profiles set terms_version = '2027-01-01'$$, '42501', null,
  'nor the version');
select throws_ok($$update public.profiles set terms_accepted_at = now()$$, '42501', null, 'nor the date');

-- MARK: Accounts onboarded before

select pg_temp.login((select old from ids));
select lives_ok('select public.complete_onboarding()', 'an account onboarded before stays valid');
select is(pg_temp.hint($$select public.accept_terms('2026-09-29', false)$$), 'sensitive_consent_required',
  'onboarded without a consent on record: false is refused');
select is(pg_temp.hint($$select public.accept_terms('2026-09-29', null)$$), 'sensitive_consent_required',
  'and so is null');
select lives_ok($$select public.accept_terms('2026-09-29', true)$$, 'the consent can be given');

select pg_temp.login((select con from ids));
select lives_ok($$select public.accept_terms('2026-10-01', false)$$, 'with a consent on record, false records the terms');
select lives_ok($$select public.accept_terms('2026-11-01', null)$$, 'and so does null');
select is((select jsonb_build_object('version', terms_version, 'terms', terms_accepted_at = now(),
    'consent', sensitive_consent_at) from public.profiles where id = (select con from ids)),
  '{"version": "2026-11-01", "terms": true, "consent": "2026-01-01T00:00:00+00:00"}'::jsonb,
  'the newer version is recorded and the earlier consent kept');

select pg_temp.login((select kept from ids));
select is(pg_temp.hint($$select public.accept_terms('2026-09-29', true)$$), 'not_found',
  'an account deleted and kept for safety: not_found');

reset role;

select is((select terms_accepted_at from public.profiles where id = (select ben from ids)), null::timestamptz,
  'another account is untouched');
select is((select sensitive_consent_at from public.profiles where id = (select kept from ids)), null::timestamptz,
  'the kept account records nothing');

-- MARK: Consent log

select is((select jsonb_agg(jsonb_build_object('version', terms_version, 'consent', sensitive_consent) order by id)
    from private.consent_events where user_id = (select ana from ids)),
  '[{"version": "2026-09-29", "consent": true}, {"version": "2026-09-29", "consent": false}]'::jsonb,
  'every accepted call is logged, in order');
select is((select count(*) from private.consent_events where user_id in (select old from ids union select con from ids)),
  3::bigint, 'the calls of accounts onboarded before are logged too, refused ones are not');
select is(pg_temp.hint($$update private.consent_events set sensitive_consent = true$$), 'append_only',
  'the log cannot be changed');
select is(pg_temp.hint($$delete from private.consent_events$$), 'append_only', 'nor rows deleted');
select is(pg_temp.hint($$truncate private.consent_events$$), 'append_only', 'nor emptied');
delete from auth.users where id = (select ana from ids);
select is((select count(*) from private.consent_events where user_id = (select ana from ids)), 0::bigint,
  'the rows go with the account');

select * from finish();
rollback;
