-- The portrait (20260930000801): only an approved photo whose face isn't known to be missing opens a card
-- or a sign-up. Pending, refused and faceless photos never reach a card, and complete_onboarding refuses
-- them (`portrait_required`). The moderation verdict records the face.
begin;
create extension if not exists pgtap with schema extensions;
select plan(16);

-- Everything onboarding asks for, photos aside.
create function pg_temp.person(p_email text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id, email_confirmed_at, phone, phone_confirmed_at)
  values (v_id, p_email, 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000', now(),
    '336' || lpad((floor(random() * 1e8))::bigint::text, 8, '0'), now());
  update public.profiles set name = split_part(p_email, '@', 1), birthdate = '1995-05-05', gender = 'woman',
      terms_version = '2026-09-30', terms_accepted_at = now(), sensitive_consent_at = now()
    where id = v_id;
  insert into public.profile_sports (user_id, sport_id, per_week, position) values (v_id, 'running', 3, 0);
  return v_id;
end $$;

create function pg_temp.photo(p_user uuid, p_name text, p_position int) returns uuid language sql as $$
  insert into public.profile_media (user_id, key, position, width, height)
    values (p_user, 'u/' || p_user || '/photos/' || p_name || '.jpg', p_position, 100, 100)
    returning id;
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

create function pg_temp.finish(p_user uuid) returns text language plpgsql as $$
declare
  v_hint text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_hint := pg_temp.hint('select public.complete_onboarding()');
  reset role;
  return v_hint;
end $$;

create function pg_temp.card_keys(p_user uuid) returns text[] language sql as $$
  select array(select split_part(m ->> 'key', '/', 4) from public.profile_cards c,
    jsonb_array_elements(c.card -> 'media') m where c.user_id = p_user);
$$;

grant execute on all functions in schema pg_temp to authenticated;

create temp table ids as select pg_temp.person('ana@test.dev') as ana, pg_temp.person('ben@test.dev') as ben;
create temp table photos as select
  pg_temp.photo((select ana from ids), 'first', 0) as first,
  pg_temp.photo((select ana from ids), 'second', 1) as second;

-- MARK: Sign-up

select is(pg_temp.finish((select ana from ids)), 'portrait_required',
  'a photo moderation has not judged yet does not finish a sign-up');

select ok(public.apply_media_verdict((select first from photos), 'rejected', '{Explicit Nudity 97%}', true),
  'the verdict applies to a pending photo');
select is((select face from public.profile_media where id = (select first from photos)), true,
  'the verdict records the face');
select is(pg_temp.finish((select ana from ids)), 'portrait_required', 'a refused photo does not finish a sign-up');

select ok(public.apply_media_verdict((select second from photos), 'approved', '{}', false),
  'an approved photo without a face');
select is(pg_temp.finish((select ana from ids)), 'portrait_required',
  'a photo without a face does not finish a sign-up');
select is((select photo_count::int from public.profiles where id = (select ana from ids)), 0,
  'without a portrait the profile counts no photo, so it stays out of Discover');
select is(pg_temp.card_keys((select ana from ids)), array['second.jpg'],
  'the refused photo is never on the card');

select ok(public.apply_media_verdict(pg_temp.photo((select ana from ids), 'third', 2), 'approved', '{}', true),
  'an approved photo with a face');
select is(pg_temp.finish((select ana from ids)), null, 'an approved photo with a face finishes the sign-up');
select is(pg_temp.card_keys((select ana from ids)), array['third.jpg', 'second.jpg'],
  'the photo with a face opens the card, the others follow in order');
select is((select photo_count::int from public.profiles where id = (select ana from ids)), 2,
  'with a portrait every approved photo counts');

-- MARK: Review and legacy photos

select ok(public.apply_media_verdict(pg_temp.photo((select ben from ids), 'borderline', 0), 'review', '{Weapons 70%}',
  true), 'a borderline photo');
select is(
  (select status::text from public.profile_media where user_id = (select ben from ids)),
  'pending', 'review leaves it pending for a person');
select is(pg_temp.finish((select ben from ids)), 'portrait_required', 'a photo waiting for a person is not a portrait');

-- A photo from before the face check (face unknown), approved by a person: it may be the portrait.
update public.profile_media set status = 'approved', face = null where user_id = (select ben from ids);
select is(pg_temp.finish((select ben from ids)), null, 'an approved photo whose face was never checked still counts');

select * from finish();
rollback;
