-- An email or phone number a banned account used (compared normalised: `jo+2@gmail.com` is
-- `jo@gmail.com`, 20260927000001) is refused as "already used", like an address another account has:
--
-- - `email_taken` / `phone_taken` instead of `banned`, and a message that says nothing about a ban, so
--   whoever types someone's address can't learn that they were banned. Apple and Google sign-ins keep
--   `banned`: only their owner can use them.
-- - Refused when the code is asked for (`email_change`, `phone_change` set by Auth), not after the code
--   is typed: the change used to be accepted, the code sent, then turned down with a server error.
-- - No code goes out to such an address or number: Auth calls the Send Email / Send SMS hook before it
--   writes `email_change` / `phone_change`, so the trigger alone would still send one. auth-email skips
--   the email and phone-code refuses before Lookup (`public.identity_is_banned`).

create or replace function private.identity_banned(p_kind text, p_value text, p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from private.identity_marks m
    where m.state = 'banned' and m.kind = p_kind and m.user_id <> p_user
      and m.hash = private.identity_hash(p_kind, case p_kind
        when 'email' then private.normalize_email(p_value)
        else private.normalize_phone(p_value) end));
$$;

create or replace function private.refuse_banned_identity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (tg_op = 'INSERT' or new.email is distinct from old.email)
      and private.identity_banned('email', new.email, new.id)
    or tg_op = 'UPDATE' and coalesce(new.email_change, '') <> '' and new.email_change is distinct from old.email_change
      and private.identity_banned('email', new.email_change, new.id) then
    perform private.fail('email_taken', 'this email is already used by another account');
  end if;
  if (tg_op = 'INSERT' or new.phone is distinct from old.phone)
      and private.identity_banned('phone', new.phone, new.id)
    or tg_op = 'UPDATE' and coalesce(new.phone_change, '') <> '' and new.phone_change is distinct from old.phone_change
      and private.identity_banned('phone', new.phone_change, new.id) then
    perform private.fail('phone_taken', 'this phone number is already used by another account');
  end if;
  return new;
end;
$$;

drop trigger auth_users_refuse_banned on auth.users;
create trigger auth_users_refuse_banned before insert or update of email, phone, email_change, phone_change
  on auth.users for each row execute function private.refuse_banned_identity();

revoke execute on function private.identity_banned(text, text, uuid) from public, anon, authenticated;

-- For auth-email and phone-code (service role): an email or phone number a banned account other than
-- `p_user` used. They answer it like a taken one, so the reply says nothing about a ban.
create function public.identity_is_banned(p_kind text, p_value text, p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_kind in ('email', 'phone') and private.identity_banned(p_kind, p_value, p_user);
$$;

revoke execute on function public.identity_is_banned(text, text, uuid) from public, anon, authenticated;
grant execute on function public.identity_is_banned(text, text, uuid) to service_role;
