-- Every photo or video the moderation check flagged, from chats and profiles: the base for
-- actions (someone flagged too often) and metrics. Server-side only: no client can read it.

create table public.media_flags (
  id bigint generated always as identity primary key,
  user_id uuid references public.profiles (id) on delete set null,
  -- Where it was sent: a chat message, or a profile photo.
  context text not null check (context in ('chat', 'profile')),
  key text not null,
  -- 'rejected' (clearly against the guidelines) or 'review' (borderline).
  verdict text not null check (verdict in ('rejected', 'review')),
  labels text[] not null default '{}',
  created_at timestamptz not null default now()
);

create index media_flags_user_idx on public.media_flags (user_id, created_at desc);
create index media_flags_created_idx on public.media_flags (created_at desc);

alter table public.media_flags enable row level security;
grant all on public.media_flags to service_role;

-- People flagged in the last 30 days, most first (Studio: select * from private.flagged_users).
create view private.flagged_users as
  select user_id,
         count(*) as flags,
         count(*) filter (where verdict = 'rejected') as rejected,
         count(*) filter (where context = 'chat') as in_chats,
         max(created_at) as last_flag
  from public.media_flags
  where created_at > now() - interval '30 days'
  group by user_id
  order by flags desc;
