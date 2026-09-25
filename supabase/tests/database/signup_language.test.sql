-- Sign-up language: the new profile takes the language the app sent, English otherwise.
-- Run with `supabase test db`.

begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

create function pg_temp.sign_up(p_meta jsonb) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id, raw_user_meta_data)
  values (v_id, v_id || '@test.dev', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000', p_meta);
  return v_id;
end $$;

-- Signed up first: a row inserted by a function isn't visible to the statement that called it.
create temp table people as select
  pg_temp.sign_up('{"language": "fr"}') as fr,
  pg_temp.sign_up('{"language": "xx"}') as unknown,
  pg_temp.sign_up('{}') as none;

select is((select language from public.profiles where id = (select fr from people)), 'fr',
  'the profile starts in the language sent at sign-up');
select is((select language from public.profiles where id = (select unknown from people)), 'en',
  'an unknown language falls back to English');
select is((select language from public.profiles where id = (select none from people)), 'en',
  'no language is English');

select * from finish();
rollback;
