-- Deleting an account on the member's request, without the app (Google Play asks for a way; the website says:
-- write to support from the account's email, or give its phone number and confirm; deleted within 30 days at
-- most, confirmed by email).
--
-- An admin, in sophros, checks who is asking, then calls admin_delete_account with a reason and the request's
-- reference (its support reference, DR-XXXXXX, or 'email' for a message outside the support requests). It:
--   - records it in the audit log (`account.delete`, append-only), with the outcome expected now;
--   - takes the account's email and language before anything changes (a kept account's email is freed);
--   - queues `account.staff_delete`: db-events runs the same deletion as delete-account does for the member
--     (_shared/account_deletion.ts: kept for safety when banned, held or under an open report, else erased
--     with its chats, media, selfies and exports), then emails the member a confirmation in their language,
--     Reply-To the support address.
-- admin_account_deletion_preview tells sophros beforehand which it will be. Only admins: nothing undoes it.

-- A deletion queued and not done yet (one at a time per account).
create function private.staff_deletion_pending(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from private.outbox o
    where o.event = 'account.staff_delete' and o.payload ->> 'userId' = p_user::text
      and o.delivered_at is null and o.failed_at is null and o.discarded_at is null);
$$;

-- sophros, before asking for confirmation: erased or kept for safety (and why), and where the confirmation
-- will go. `pending`: a deletion is already queued.
create function public.admin_account_deletion_preview(p_actor text, p_user uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_why jsonb;
begin
  perform private.require_staff(p_actor, 'admin');
  if not exists (select 1 from public.profiles where id = p_user) then
    perform private.fail('not_found', 'no such account');
  end if;
  v_why := private.retention_basis(p_user);
  return jsonb_build_object(
    'outcome', case when v_why is null then 'erase' else 'keep' end,
    'basis', v_why ->> 'basis',
    'deleted', (select deleted_at is not null from public.profiles where id = p_user),
    'pending', private.staff_deletion_pending(p_user),
    'email', (select u.email from auth.users u where u.id = p_user));
end;
$$;

-- Queues the deletion (see above) and answers {"expected": "erase" | "keep"}. The database decides again
-- when it runs: a report or a hold arriving meanwhile keeps the account.
create function public.admin_delete_account(p_actor text, p_user uuid, p_reason text, p_reference text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reason text := trim(coalesce(p_reason, ''));
  v_reference text := trim(coalesce(p_reference, ''));
  v_profile public.profiles;
  v_email text;
  v_expected text;
begin
  perform private.require_staff(p_actor, 'admin');
  if v_reason = '' or char_length(v_reason) > 1000 then
    perform private.fail('reason_required', 'say why, in 1000 characters at most');
  end if;
  if lower(v_reference) = 'email' then
    v_reference := 'email';
  elsif upper(v_reference) ~ '^DR-[A-Z0-9]{6}$'
        and exists (select 1 from private.support_requests where reference = upper(v_reference)) then
    v_reference := upper(v_reference);
  else
    perform private.fail('invalid_reference', 'give the support reference (DR-XXXXXX) or "email"');
  end if;
  select * into v_profile from public.profiles where id = p_user for update;
  if not found then
    perform private.fail('not_found', 'no such account');
  end if;
  if v_profile.deleted_at is not null then
    perform private.fail('already_deleted', 'this account is deleted already');
  end if;
  if private.staff_deletion_pending(p_user) then
    perform private.fail('already_requested', 'a deletion of this account is on its way');
  end if;

  select u.email into v_email from auth.users u where u.id = p_user;
  v_expected := case when private.retention_basis(p_user) is null then 'erase' else 'keep' end;
  perform private.audit(p_actor, 'account.delete', p_user, v_reference, v_reason,
    jsonb_build_object('expected', v_expected));
  perform private.emit('account.staff_delete', jsonb_build_object('userId', p_user, 'email', v_email,
    'language', v_profile.language, 'reference', v_reference));
  return jsonb_build_object('expected', v_expected);
end;
$$;

insert into private.outbox_policies (event, retry_budget, expires_after, push_ttl, providers)
  values ('account.staff_delete', '24 hours', null, null, '{stream,r2,resend}');

revoke execute on function public.admin_account_deletion_preview(text, uuid), public.admin_delete_account(text, uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.admin_account_deletion_preview(text, uuid), public.admin_delete_account(text, uuid, text, text)
  to service_role;
revoke execute on function private.staff_deletion_pending(uuid) from public, anon, authenticated;
