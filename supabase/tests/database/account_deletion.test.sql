-- Deleting an account (20260928000131, 20260928000132): a reported, held or banned one is kept for members'
-- safety (hidden, signed out, everything retained, the reason recorded); any other is erased, as before.
begin;
create extension if not exists pgtap with schema extensions;
select plan(41);

create function pg_temp.person(p_email text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id)
  values (v_id, p_email, 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  update public.profiles set onboarded_at = now(), birthdate = '1990-01-01' where id = v_id;
  return v_id;
end $$;

create function pg_temp.login(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

grant execute on all functions in schema pg_temp to authenticated;
-- ana reports bo (and so blocks him); cy liked by bo and matched with him; di has nothing; ed is banned.
create temp table ids as select pg_temp.person('ana@audit.test') as ana, pg_temp.person('bo@audit.test') as bo,
  pg_temp.person('cy@audit.test') as cy, pg_temp.person('di@audit.test') as di, pg_temp.person('ed@audit.test') as ed;
grant select on ids to authenticated;
insert into private.staff (email, role) values ('sup@drafft.test', 'support');

insert into public.reports (reporter, reported, reason, details)
  select ana, bo, 'harassment', 'kept' from ids;
insert into public.matches (user_a, user_b) select least(bo, cy), greatest(bo, cy) from ids;
insert into public.swipes (swiper, target, action) select bo, di, 'like' from ids;
insert into public.push_tokens (token, user_id, environment) select 'bo-token', bo, 'production' from ids;
insert into private.devices (user_id, install_id, model) select bo, gen_random_uuid(), 'iPhone' from ids;
insert into auth.sessions (id, user_id) select gen_random_uuid(), bo from ids;
insert into public.profile_media (user_id, key, position, width, height)
  select bo, 'u/' || bo || '/photos/a.jpg', 0, 100, 100 from ids;
update public.profiles set moderation = 'banned' where id = (select ed from ids);
insert into public.blocks (blocker, blocked) select di, ed from ids;

-- MARK: Who is kept

select is(private.retention_basis((select di from ids)), null, 'never reported nor held: nothing to keep');
select is(private.retention_basis((select bo from ids)) ->> 'basis', 'report', 'reported (open report): kept for the report');
select is(private.retention_basis((select ed from ids)) ->> 'basis', 'ban', 'banned: kept for the ban');
update public.reports set handled_at = now() where reported = (select bo from ids);
select is(private.retention_basis((select bo from ids)) ->> 'basis', 'report', 'a closed report still counts');
update public.profiles set moderation = 'review' where id = (select di from ids);
update public.profiles set moderation = null where id = (select di from ids);
select is(private.retention_basis((select di from ids)) ->> 'basis', 'hold', 'a hold lifted since still counts');
delete from private.moderation_log where user_id = (select di from ids);

-- MARK: Erased (not reported, not held)

select is(public.retain_deleted_account((select di from ids)), '{"retained": false}'::jsonb, 'any other account is not kept');
select ok((select deleted_at is null and not paused from public.profiles where id = (select di from ids)),
  'and is left untouched, for delete-account to erase');
select is((select count(*) from private.account_deletions where user_id = (select di from ids)), 0::bigint, 'no record');

-- MARK: Kept: reported

select is(public.retain_deleted_account((select bo from ids)), '{"retained": true, "basis": "report"}'::jsonb,
  'a reported account is kept');
select is(public.retain_deleted_account((select bo from ids)), '{"retained": true, "basis": "report"}'::jsonb,
  'asking again answers the same (idempotent)');
select ok((select deleted_at is not null and paused from public.profiles where id = (select bo from ids)),
  'marked deleted and paused');
select is((select legal_basis || ' ' || basis || ' ' || jsonb_array_length(refs -> 'reports')
  from private.account_deletions where user_id = (select bo from ids)), 'member_safety report 1',
  'the record says why: the basis, the report, members'' safety');
select is((select identities ->> 'email' from private.account_deletions where user_id = (select bo from ids)),
  'bo@audit.test', 'the original email is kept in the record');
select ok((select count(*) > 0 from private.deleted_identities where user_id = (select bo from ids)),
  'its identities are digested, to link a new sign-up');

-- Everything is retained.
select is((select count(*) from public.reports where reported = (select bo from ids)), 1::bigint, 'the report is kept');
select is((select count(*) from public.profile_media where user_id = (select bo from ids)), 1::bigint, 'media rows are kept');
select is((select count(*) from private.devices where user_id = (select bo from ids)), 1::bigint, 'devices are kept');
select is((select count(*) from public.swipes where swiper = (select bo from ids)), 1::bigint, 'likes are kept');
select is((select count(*) from public.matches where (select bo from ids) in (user_a, user_b)), 1::bigint,
  'matches are kept (ended)');

-- Signed out for good.
select is((select count(*) from public.push_tokens where user_id = (select bo from ids)), 0::bigint, 'push tokens deleted');
select is((select count(*) from auth.sessions where user_id = (select bo from ids)), 0::bigint, 'sessions revoked');
select ok((select banned_until > now() + interval '99 years' from auth.users where id = (select bo from ids)),
  'the Auth user is banned');
select is((select email::text from auth.users where id = (select bo from ids)), (select bo from ids)::text || '@deleted.drafft.invalid',
  'its email is freed');
select ok(exists (select 1 from private.outbox where event = 'account.soft_deleted'
  and payload ->> 'userId' = (select bo from ids)::text), 'db-events bans it in Stream and revokes its tokens');

-- Out of sight.
select ok((select ended_at is not null from public.matches where (select bo from ids) in (user_a, user_b)), 'its match ended');
select ok(exists (select 1 from private.outbox o join public.matches m on o.payload ->> 'matchId' = m.id::text
  where o.event = 'match.ended' and (select bo from ids) in (m.user_a, m.user_b)), 'db-events freezes the chat');
set local role authenticated;
select pg_temp.login((select cy from ids));
select is((select count(*) from public.my_matches()), 0::bigint, 'the match leaves the other person''s chats');
select is((select count(*) from public.get_cards(array[(select bo from ids)])), 0::bigint, 'its card is never served');
select pg_temp.login((select di from ids));
select is((select count(*) from public.liked_me()), 0::bigint, 'its like leaves the Likes tab');
select pg_temp.login((select cy from ids));
select throws_ok(format('select public.swipe(%L, ''like'')', (select bo from ids)), 'P0001', 'profile not available',
  'nobody can swipe on it');
reset role;

-- A hold lifted later doesn't bring it back.
update public.profiles set moderation = 'review' where id = (select bo from ids);
update public.profiles set moderation = null where id = (select bo from ids);
select ok((select paused from public.profiles where id = (select bo from ids)), 'lifting a hold keeps it paused');

-- MARK: Kept: banned

select is(public.retain_deleted_account((select ed from ids)) ->> 'basis', 'ban', 'a banned account is kept');
set local role authenticated;
select pg_temp.login((select di from ids));
select is((select count(*) from public.blocked_users()), 0::bigint, 'it leaves the blocked list');
reset role;
select throws_ok($$ select pg_temp.person('ed@audit.test') $$, 'P0001', 'this account can no longer be used on drafft',
  'signing up again with a banned email is refused');

-- MARK: Signing up again after a report

create temp table again as select pg_temp.person('bo@audit.test') as bo2;
select is((select count(*) from private.account_links
  where user_id = (select bo2 from again) and deleted_user_id = (select bo from ids) and via = 'email'), 1::bigint,
  'a reported account can sign up again, linked to the old one');
select ok(private.admin_related_accounts((select bo2 from again)) @> jsonb_build_array(jsonb_build_object('via', 'previous account')),
  'sophros shows the previous account');
select ok(private.admin_related_accounts((select bo from ids)) @> jsonb_build_array(jsonb_build_object('via', 'later account')),
  'and the later one from the old account');

-- MARK: sophros

select ok(public.admin_users('sup@drafft.test', '', 'deleted') @> jsonb_build_array(jsonb_build_object('id', (select bo from ids))),
  'the deleted filter lists it');
select is(public.admin_account_deletion('sup@drafft.test', (select bo from ids)) ->> 'basis', 'report',
  'its page reads the record');

-- MARK: Erased for good

delete from auth.users where id = (select di from ids);
select is((select count(*) from public.profiles where id = (select di from ids)), 0::bigint,
  'an account that isn''t kept is erased with its Auth user, as before');

-- MARK: Grants

select ok(not has_function_privilege('authenticated', 'public.retain_deleted_account(uuid)', 'execute')
  and not has_function_privilege('anon', 'public.retain_deleted_account(uuid)', 'execute')
  and has_function_privilege('service_role', 'public.retain_deleted_account(uuid)', 'execute'),
  'only delete-account (service role) can keep an account');

select * from finish();
rollback;
