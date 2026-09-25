-- The app sends its language with the sign-up (`options.data.language`): the new profile starts in it,
-- so the confirmation email (auth-email) and the first pushes are in that language, not English until
-- onboarding saves it. Anything else, or nothing, is English.
create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_language text := new.raw_user_meta_data ->> 'language';
begin
  insert into public.profiles (id, language)
  values (new.id, case when v_language in ('en', 'fr', 'es', 'de', 'it', 'pt', 'nl') then v_language else 'en' end);
  insert into public.wallets (user_id) values (new.id);
  return new;
end;
$$;
