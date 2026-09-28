-- A support reply is sent once (decision 4.3). sophros makes a key when the reply form opens and sends it
-- with the reply; the database keeps it on the message, unique, so a second send of the same form (a
-- double click, a retried request, ⌘↵ twice) creates no second message and no second email.

alter table private.support_messages add column idempotency_key uuid;

create unique index support_messages_idempotency_key on private.support_messages (idempotency_key)
  where idempotency_key is not null;

drop function public.admin_reply_support(text, bigint, text, boolean);

-- Sends a reply to the person (queued: db-events emails it), and closes the request unless asked not to.
-- A key already used: nothing happens again (no message, no email, no audit), and the call succeeds.
create function public.admin_reply_support(
  p_actor text, p_id bigint, p_body text, p_close boolean default true, p_idempotency_key uuid default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_message bigint;
  v_request private.support_requests;
begin
  perform private.require_staff(p_actor, 'support');
  if coalesce(trim(p_body), '') = '' then
    perform private.fail('empty_reply', 'write the reply first');
  end if;
  select * into v_request from private.support_requests where id = p_id;
  if not found then
    perform private.fail('not_found', 'no such request');
  end if;
  insert into private.support_messages (request_id, author, body, idempotency_key)
    values (p_id, lower(trim(p_actor)), trim(p_body), p_idempotency_key)
    on conflict (idempotency_key) where idempotency_key is not null do nothing
    returning id into v_message;
  if v_message is null then
    return;
  end if;
  perform private.emit('support.reply', jsonb_build_object('id', v_message));
  if p_close then
    update private.support_requests set handled_at = now(), handled_by = lower(trim(p_actor)) where id = p_id;
  end if;
  perform private.audit(p_actor, 'support.reply', v_request.user_id, v_request.reference, null,
    jsonb_build_object('closed', p_close));
end;
$$;

revoke execute on function public.admin_reply_support(text, bigint, text, boolean, uuid) from public, anon, authenticated;
grant execute on function public.admin_reply_support(text, bigint, text, boolean, uuid) to service_role;
