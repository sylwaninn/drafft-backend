-- Deleting an account on the member's request, without the app (Google Play asks for a way; the website says:
-- write to support from the account's email, or from another address giving its phone number and confirming;
-- deleted within 30 days at most, confirmed by email).
--
-- An admin, in sophros, checks who is asking, then calls admin_delete_account with a reason and the request's
-- reference (its support reference, DR-XXXXXX, or 'email' for a message outside the support requests). It:
--   - records it in the audit log (`account.delete`, append-only), with the outcome expected now;
--   - keeps, in private.staff_deletions, where the confirmation goes: the account's email and, when the member
--     wrote from another address (a DR- request's), that one too, and the account's language, taken before
--     anything changes (a kept account's email is freed). The addresses are cleared once the confirmation is
--     sent, and the row goes after 30 days: the queue carries only the row's id;
--   - queues `account.staff_delete`: db-events runs the same deletion as delete-account does for the member
--     (_shared/erase.ts, deleteAccount: kept for safety when banned, held or under an open report, else erased
--     with its chats, media, selfies and exports), records the real outcome (staff_deletion_done: `account.deleted`
--     in the audit log), then emails the confirmation in the member's language, Reply-To the support address; with
--     no address at all, the team is told instead.
-- admin_account_deletion_preview tells sophros beforehand which it will be and where the email goes. Only admins:
-- nothing undoes it. Outcomes are `erased` or `kept` everywhere (SQL, db-events, the audit log).

create table private.staff_deletions (
  id bigint generated always as identity primary key,
  -- The account may be erased since: no foreign key.
  user_id uuid not null,
  reference text not null check (reference = 'email' or reference ~ '^DR-[A-Z0-9]{6}$'),
  -- Where the confirmation goes, until it is sent.
  emails text[] not null default '{}' check (cardinality(emails) <= 2),
  language text,
  requested_by text not null,
  requested_at timestamptz not null default now(),
  outcome text check (outcome in ('erased', 'kept')),
  done_at timestamptz,
  emailed_at timestamptz,
  check ((outcome is null) = (done_at is null)),
  check (emailed_at is null or (done_at is not null and cardinality(emails) = 0))
);

create index staff_deletions_user_idx on private.staff_deletions (user_id, requested_at desc);

-- A deletion queued and not done yet (one at a time per account): its event still on its way.
create function private.staff_deletion_pending(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from private.staff_deletions d
    join private.outbox o on o.event = 'account.staff_delete' and o.payload ->> 'id' = d.id::text
    where d.user_id = p_user and d.done_at is null
      and o.delivered_at is null and o.failed_at is null and o.discarded_at is null);
$$;

-- The reference, as the audit log keeps it: 'email', or an existing DR- request (`invalid_reference` for
-- anything else, `unknown_reference` for a DR- reference no request has). Its request's address, if any.
create function private.deletion_reference(p_reference text, out reference text, out email text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_reference text := upper(trim(coalesce(p_reference, '')));
begin
  if v_reference = 'EMAIL' then
    reference := 'email';
    return;
  end if;
  if v_reference !~ '^DR-[A-Z0-9]{6}$' then
    perform private.fail('invalid_reference', 'give the support reference (DR-XXXXXX) or "email"');
  end if;
  select r.reference, lower(r.email) into reference, email from private.support_requests r where r.reference = v_reference;
  if reference is null then
    perform private.fail('unknown_reference', 'no support request has this reference');
  end if;
end;
$$;

-- Where the confirmation goes: the account's email, and the request's address when it differs (null: none).
create function private.deletion_emails(p_user uuid, p_request_email text)
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(distinct e order by e), '{}') from (
    select lower(u.email) as e from auth.users u where u.id = p_user and coalesce(u.email, '') <> ''
      and lower(u.email) not like '%@deleted.drafft.invalid'
    union select lower(p_request_email) where coalesce(p_request_email, '') <> '') x;
$$;

-- sophros, before asking for confirmation. One of:
--   {"status": "deleted"}                       the account is deleted already (kept for safety)
--   {"status": "pending"}                       a deletion is on its way
--   {"status": "ready", "outcome": "erased", "emails": [...], "emailed": bool}
--   {"status": "ready", "outcome": "kept", "basis": "ban" | "hold" | "report", "emails": [...], "emailed": bool}
-- `emails`: where the confirmation will go (with `p_reference`, the request's address too); `emailed`: whether one
-- will be sent at all (otherwise the team is told, to confirm another way).
create function public.admin_account_deletion_preview(p_actor text, p_user uuid, p_reference text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_why jsonb;
  v_request_email text;
  v_emails text[];
begin
  perform private.require_staff(p_actor, 'admin');
  if not exists (select 1 from public.profiles where id = p_user) then
    perform private.fail('not_found', 'no such account');
  end if;
  if (select deleted_at is not null from public.profiles where id = p_user) then
    return jsonb_build_object('status', 'deleted');
  end if;
  if private.staff_deletion_pending(p_user) then
    return jsonb_build_object('status', 'pending');
  end if;
  if nullif(trim(coalesce(p_reference, '')), '') is not null then
    select d.email into v_request_email from private.deletion_reference(p_reference) d;
  end if;
  v_emails := private.deletion_emails(p_user, v_request_email);
  v_why := private.retention_basis(p_user);
  return jsonb_build_object('status', 'ready', 'outcome', case when v_why is null then 'erased' else 'kept' end,
      'emails', to_jsonb(v_emails), 'emailed', cardinality(v_emails) > 0)
    || case when v_why is null then '{}'::jsonb else jsonb_build_object('basis', v_why ->> 'basis') end;
end;
$$;

-- Queues the deletion (see above) and answers {"expected": "erased" | "kept", "emails": [...], "emailed": bool}.
-- The database decides again when it runs: a report or a hold arriving meanwhile keeps the account.
-- Errors: reason_required, invalid_reference, unknown_reference, not_found, already_deleted, already_requested.
create function public.admin_delete_account(p_actor text, p_user uuid, p_reason text, p_reference text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reason text := trim(coalesce(p_reason, ''));
  v_reference record;
  v_profile public.profiles;
  v_emails text[];
  v_expected text;
  v_id bigint;
begin
  perform private.require_staff(p_actor, 'admin');
  if v_reason = '' or char_length(v_reason) > 1000 then
    perform private.fail('reason_required', 'say why, in 1000 characters at most');
  end if;
  select * into v_reference from private.deletion_reference(p_reference);
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

  v_emails := private.deletion_emails(p_user, v_reference.email);
  v_expected := case when private.retention_basis(p_user) is null then 'erased' else 'kept' end;
  perform private.audit(p_actor, 'account.delete', p_user, v_reference.reference, v_reason,
    jsonb_build_object('expected', v_expected, 'emails', cardinality(v_emails)));
  insert into private.staff_deletions (user_id, reference, emails, language, requested_by)
    values (p_user, v_reference.reference, v_emails, v_profile.language, lower(trim(p_actor)))
    returning id into v_id;
  perform private.emit('account.staff_delete', jsonb_build_object('id', v_id));
  return jsonb_build_object('expected', v_expected, 'emails', to_jsonb(v_emails), 'emailed', cardinality(v_emails) > 0);
end;
$$;

-- db-events: the deletion to run (null once it has gone after 30 days).
create function public.staff_deletion(p_id bigint)
returns table (user_id uuid, reference text, emails text[], language text, outcome text)
language sql
stable
security definer
set search_path = ''
as $$
  select d.user_id, d.reference, d.emails, d.language, d.outcome from private.staff_deletions d where d.id = p_id;
$$;

-- db-events, once deleteAccount has run: the real outcome, in the audit log too (`account.deleted`).
create function public.staff_deletion_done(p_id bigint, p_outcome text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  d private.staff_deletions;
begin
  if p_outcome not in ('erased', 'kept') then
    perform private.fail('invalid_outcome', 'erased or kept');
  end if;
  update private.staff_deletions set outcome = p_outcome, done_at = now() where id = p_id and done_at is null
    returning * into d;
  if d.id is not null then
    perform private.audit(d.requested_by, 'account.deleted', d.user_id, d.reference, 'on the member''s request',
      jsonb_build_object('outcome', p_outcome));
  end if;
end;
$$;

-- db-events, once the confirmation is sent (or the team told there is nowhere to send it): the addresses go.
create function public.staff_deletion_emailed(p_id bigint)
returns void
language sql
security definer
set search_path = ''
as $$
  update private.staff_deletions set emails = '{}', emailed_at = now() where id = p_id and done_at is not null;
$$;

insert into private.outbox_policies (event, retry_budget, expires_after, push_ttl, providers, erasure)
  values ('account.staff_delete', '24 hours', null, null, '{stream,r2,resend}', true);

revoke execute on function public.admin_account_deletion_preview(text, uuid, text),
  public.admin_delete_account(text, uuid, text, text), public.staff_deletion(bigint),
  public.staff_deletion_done(bigint, text), public.staff_deletion_emailed(bigint)
  from public, anon, authenticated;
grant execute on function public.admin_account_deletion_preview(text, uuid, text),
  public.admin_delete_account(text, uuid, text, text), public.staff_deletion(bigint),
  public.staff_deletion_done(bigint, text), public.staff_deletion_emailed(bigint)
  to service_role;
revoke all on function private.staff_deletion_pending(uuid), private.deletion_reference(text),
  private.deletion_emails(uuid, text) from public, anon, authenticated;

-- The addresses never outlive the queue's 30 days, even for a deletion whose event failed: the row goes, the audit
-- log keeps what was done.
select cron.schedule('staff-deletions-cleanup', '53 3 * * *', $$
  delete from private.staff_deletions where requested_at < now() - private.retention_period('outbox_dead');
$$);
