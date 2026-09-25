-- Notification settings: the app writes them on its own profile; turning messages off reaches Stream.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email, aud, role, instance_id)
values ('33333333-3333-4333-8333-333333333333', 'settings@test.dev', 'authenticated', 'authenticated',
        '00000000-0000-0000-0000-000000000000');

select is((select notify_matches and notify_likes and notify_messages and not notify_message_previews
           from public.profiles where id = '33333333-3333-4333-8333-333333333333'), true,
  'defaults match the app: all on, previews off');

set local role authenticated;
set local request.jwt.claims = '{"sub": "33333333-3333-4333-8333-333333333333", "role": "authenticated"}';
update public.profiles set notify_likes = false, notify_message_previews = true
  where id = '33333333-3333-4333-8333-333333333333';
reset role;
select is((select count(*) from private.outbox where event = 'push.preferences'
           and payload ->> 'userId' = '33333333-3333-4333-8333-333333333333'), 0::bigint,
  'other settings emit nothing');
set local role authenticated;
update public.profiles set notify_messages = false where id = '33333333-3333-4333-8333-333333333333';
reset role;

select is((select notify_likes::text || ' ' || notify_message_previews::text from public.profiles
           where id = '33333333-3333-4333-8333-333333333333'), 'false true', 'the app can write its settings');
select is((select payload ->> 'messages' from private.outbox where event = 'push.preferences'
           and payload ->> 'userId' = '33333333-3333-4333-8333-333333333333'), 'false',
  'turning messages off is sent to Stream');

select is((select notify_reactions from public.profiles where id = '33333333-3333-4333-8333-333333333333'), true,
  'reaction pushes are on by default');

select * from finish();
rollback;
