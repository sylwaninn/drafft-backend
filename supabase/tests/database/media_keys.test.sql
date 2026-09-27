-- Media keys: only the shape media-upload-url issues, under the owner's own folders (20260928000001).
-- Run with `supabase test db`.

begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

create function pg_temp.login(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
grant execute on all functions in schema pg_temp to authenticated;

create temp table ids as select gen_random_uuid() as me, gen_random_uuid() as other;
insert into auth.users (id, email, aud, role, instance_id)
  select me, 'keys-me@test.dev', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'::uuid from ids
  union all
  select other, 'keys-other@test.dev', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'::uuid from ids;
grant select on ids to authenticated;

set local role authenticated;
select pg_temp.login((select me from ids));

-- MARK: Accepted

select lives_ok(format($$select public.add_profile_media('u/%s/photos/%s.jpg', 1200, 1600)$$,
  (select me from ids), gen_random_uuid()), 'a photo key from media-upload-url is accepted');
select lives_ok(format($$select public.add_profile_media('u/%1$s/videos/%2$s.mp4', 720, 1280, null, 'video', 12,
  'u/%1$s/posters/%2$s.jpg')$$, (select me from ids), gen_random_uuid()), 'a video and its poster are accepted');
select lives_ok(format($$update public.profiles set voice_intro_key = 'u/%1$s/voice/%2$s.m4a' where id = %1$L$$,
  (select me from ids), gen_random_uuid()), 'a voice intro key is accepted');

-- MARK: Refused

select throws_ok(format($$select public.add_profile_media('u/%s/photos/../../%s/photos/x.jpg', 10, 10)$$,
  (select me from ids), (select other from ids)), '23514', null, 'a key with .. segments is refused');
select throws_ok(format($$select public.add_profile_media('u/%s/photos/./x.jpg', 10, 10)$$, (select me from ids)),
  '23514', null, 'a key with a . segment is refused');
select throws_ok(format($$select public.add_profile_media('u/%s//x.jpg', 10, 10)$$, (select me from ids)),
  '23514', null, 'a key with an empty segment is refused');
select throws_ok(format($$select public.add_profile_media('u/%s/photos/%s.jpg', 10, 10)$$,
  (select me from ids), repeat('a', 5000)), '23514', null, 'an overlong key is refused');
select throws_ok(format($$select public.add_profile_media('u/%s/photos/x.jpg', 10, 10)$$, (select other from ids)),
  '23514', null, 'a key under someone else''s prefix is refused');
select throws_ok(format($$select public.add_profile_media('u/%s/chat/x.jpg', 10, 10)$$, (select me from ids)),
  '23514', null, 'a chat key cannot become profile media');
select throws_ok(format($$select public.add_profile_media('u/%s/photos/x.mp4', 10, 10)$$, (select me from ids)),
  '23514', null, 'a photo needs an image extension');
select throws_ok(format($$select public.add_profile_media('u/%1$s/videos/v.mp4', 720, 1280, null, 'video', 12,
  'u/%1$s/posters/../../%2$s/posters/p.jpg')$$, (select me from ids), (select other from ids)),
  '23514', null, 'a poster key with .. segments is refused');
select throws_ok(format($$update public.profiles set voice_intro_key = 'u/%1$s/voice/../../%2$s/voice/v.m4a'
  where id = %1$L$$, (select me from ids), (select other from ids)), '23514', null,
  'a voice intro key with .. segments is refused');
select throws_ok(format($$update public.profiles set voice_intro_key = 'u/%1$s/photos/v.m4a' where id = %1$L$$,
  (select me from ids)), '23514', null, 'a voice intro key sits in voice/');

reset role;
select is((select count(*) from public.profile_media, ids where user_id = ids.me), 2::bigint,
  'only the valid media were stored');

select * from finish();
rollback;
