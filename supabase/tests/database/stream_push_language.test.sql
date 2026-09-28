-- A change to the name, app language or message previews reaches Stream (message pushes read them there).
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email, aud, role, instance_id)
values ('44444444-4444-4444-8444-444444444444', 'stream-user@test.dev', 'authenticated', 'authenticated',
        '00000000-0000-0000-0000-000000000000');

set local role authenticated;
set local request.jwt.claims = '{"sub": "44444444-4444-4444-8444-444444444444", "role": "authenticated"}';
update public.profiles set notify_likes = false where id = '44444444-4444-4444-8444-444444444444';
reset role;
select is((select count(*) from private.outbox where event = 'stream.user'
           and payload ->> 'userId' = '44444444-4444-4444-8444-444444444444'), 0::bigint,
  'other settings emit nothing');

update public.profiles set language = 'de' where id = '44444444-4444-4444-8444-444444444444';
select is((select count(*) from private.outbox where event = 'stream.user'
           and payload ->> 'userId' = '44444444-4444-4444-8444-444444444444'), 1::bigint,
  'a new app language is sent to Stream');

set local role authenticated;
update public.profiles set notify_message_previews = true where id = '44444444-4444-4444-8444-444444444444';
reset role;
select is((select count(*) from private.outbox where event = 'stream.user'
           and payload ->> 'userId' = '44444444-4444-4444-8444-444444444444'), 2::bigint,
  'turning previews on is sent to Stream');

select is((select providers from private.outbox_policy('stream.user')), '{stream}'::text[],
  'the event waits on Stream''s circuit');

select * from finish();
rollback;
