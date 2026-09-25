-- One pending phone change per number. Auth checks a texted code by finding THE account waiting for that
-- number: when two accounts wait for the same one (a sign-up dropped, then started again with another
-- email), it can pick the other account and turn down the right code. So a new code for a number cancels
-- the other accounts' pending changes to it.
create function private.clear_other_phone_changes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update auth.users
    set phone_change = '', phone_change_token = '', phone_change_sent_at = null
    where phone_change = new.phone_change and id <> new.id;
  return new;
end;
$$;

-- A new token is a new code sent (a first send or Resend).
create trigger on_auth_user_phone_change_sent after update of phone_change_token on auth.users
  for each row
  when (new.phone_change_token is distinct from old.phone_change_token and coalesce(new.phone_change, '') <> '')
  execute function private.clear_other_phone_changes();
