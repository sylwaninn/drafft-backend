# Discover and matching

How drafft picks the cards in someone's deck, and what happens from a swipe to a match. Everything below
lives in Postgres: `public.discover`, `private.eligible`, `public.swipe` and their neighbours in
`supabase/migrations/` (latest versions: `20260926000001_pause_freezes_account.sql` and
`20260926000002_discover_ranking.sql`). Tests: `supabase/tests/database/{core,discover,pause}.test.sql`.

## The deck in one call

`discover(p_filters jsonb, p_limit int = 20)` returns up to `p_limit` cards (1 to 50), best first. Each card
is the person's `profile_cards` row plus `age`, `distanceKm`, `superLikedMe`, `superLikeNote` and
`cardVersion`.

```
viewer ──▶ checks: signed in, not paused, has a location ──▶ activity bump (at most every 5 min)
             │
             ▼
           pool ─┬─ people who super liked the viewer
                 ├─ people boosted right now, within 50 km (or maxDistanceKm)
                 └─ nearest eligible people: KNN walk of the location index, 2 × p_limit
             │
             ▼
           every candidate re-checked: distance limit + eligibility
             │
             ▼
           order: super liked you ▸ boosted ▸ score ▸ distance ▸ id  ──▶  limit p_limit
```

The deck is recomputed on every call: nothing is stored per viewer. People swiped since the last call
drop out on their own, since a swipe makes them ineligible.

## Filters

All keys are optional. The app's filter sheet maps to them as shown.

| Key | Meaning | Absent | App |
| --- | --- | --- | --- |
| `maxDistanceKm` | Radius in km | Any distance | Slider 1 to 50; the last stop (`51`, "50+") must send nothing |
| `minAge` | Youngest age shown | 18 | Age slider lower bound |
| `maxAge` | Oldest age shown | No upper limit | Age slider upper bound; `60` means "60+" and must send nothing |
| `audience` | Genders shown (`woman`, `man`, `nonbinary`) | The viewer's own `interested_in` | Women / Men / Non-binary people; Everyone = send nothing |
| `sports` | At least one of these sports | Any sport | Sports picker |
| `sharedSportsOnly` | At least one sport in common with the viewer | `false` | "Shared sports only" |

## Who can appear

A person is eligible for a viewer (`private.eligible`) when all of these hold:

- not the viewer;
- onboarded, not paused, at least one approved photo, and a location on file;
- active in the last 30 days (see [Activity](#activity));
- age within `minAge` and `maxAge`;
- gender in the audience (the filter, or the viewer's preferences);
- **mutual preferences**: the viewer's gender is in the person's `interested_in`, or that list is empty
  (everyone);
- sports filters satisfied;
- never swiped by the viewer (like, super like or pass), no block in either direction, never matched
  (even if the match has ended).

Super likers and boosted people go through the same checks: a boost or a super like never breaks the
viewer's filters.

## Order

1. **They super liked you.** Pinned first, with their note. The card says so (`superLikedMe: true`).
2. **Boosted right now, nearby.** A boost lasts 30 minutes and puts the person at the top of the decks of
   viewers within 50 km, or within the viewer's own `maxDistanceKm` when set (so a viewer asking for
   500 km sees boosts up to 500 km). Nothing tells the viewer a card is boosted.
3. **Everyone else, by score** (ties: nearest, then id):

```
score = proximity × activity × shared sports bonus × liked-you bonus

proximity = 1 / (1 + km / 5)          1 next door, 0.5 at 5 km, 0.17 at 25 km
activity  = 1 / (1 + days idle / 3)   1 active now, 0.5 three days ago, 0.13 three weeks ago
shared    = 1 + 0.25 × min(sports in common, 2)     up to ×1.5
liked you = 1.5 if they already liked the viewer (a right swipe is a match), else 1
```

The factors multiply, so being far away or long inactive each sink a card on their own: a person 1 km
away and idle for 20 days (0.11) comes after one 4 km away and active today (0.56). The liked-you bonus
raises the match rate without saying who liked you (that stays the Likes tab's job).

| Person | km | Idle | Shared sports | Liked you | Score |
| --- | --- | --- | --- | --- | --- |
| A | 4 | now | 2 | yes | 0.56 × 1 × 1.5 × 1.5 = **1.25** |
| B | 4 | now | 2 | no | 0.56 × 1 × 1.5 = **0.83** |
| C | 1 | 3 days | 0 | no | 0.83 × 0.5 = **0.42** |
| D | 1 | 20 days | 0 | no | 0.83 × 0.13 = **0.11** |
| E | 390 | now | 0 | no | 0.013 × 1 = **0.01** |

The score is computed over the candidate pool only: the nearest `2 × p_limit` eligible people, plus super
likers and boosted people. It reorders what's close; it doesn't search the whole city for the best score.
That keeps `discover` fast whatever the density (see [Performance](#performance)).

Tuning: the constants (5 km, 3 days, +25 % per sport, ×1.5, 2 × pool, 50 km boost radius) live in
`public.discover`. Changing them is a new migration with `create or replace function`, plus the
expectations in `discover.test.sql`.

## Activity

`profiles.last_active_at` decides who counts as active (30-day cutoff) and feeds the activity factor. It
moves when the person:

- opens Discover (`discover`), swipes (`swipe`), starts a boost (`start_boost`): through
  `private.touch_active`, at most one write every 5 minutes;
- sends a location (`set_location`).

## Swipes

`swipe(p_target, p_action, p_opener, p_note)` with `like`, `superlike` or `pass`. Each pair is swiped once
(`already_swiped`).

- **Onboarding first**: `discover`, `swipe`, `undo_last_swipe` and `start_boost` refuse an account that
  hasn't finished onboarding (`onboarding_required`). Onboarding is where the 18+ check happens.
- **Who can be liked**: a like or super like checks the person liked again, as Discover does: 18 or older,
  and their preferences include the liker's gender (`not_eligible`). Answering someone who already liked
  you is always possible. A pass is never checked.
- **Likes**: 20 per rolling 24 hours for free accounts (`daily_like_limit`), unlimited with drafft tempo.
  Super likes and passes don't count.
- **Super likes**: spend one from `wallets.super_likes` (`no_super_likes` at zero). They can carry a note
  (140 characters), shown on the card in the other person's deck and posted in the chat if they match.
- **Openers**: a like or super like can carry the first message (text, icebreaker reply, photo reply, or a
  session proposal). It is delivered when the match forms: in the chat, or as a real session.
- **Matching**: when both people liked (like or super like) each other, a match is created. A per-pair
  advisory lock makes two simultaneous likes still match. The match creates the Stream channel, posts the
  notes and openers, and pushes both people (`db-events`, `match.created`).
- **Undo** (`undo_last_swipe`): the caller's last swipe, within 10 minutes, if it didn't make a match. A
  super like is refunded.
- **Who liked me** (`liked_me`): likes and super likes not answered yet, super likes first. Paused and
  blocked people are left out.

## Boosts

`start_boost()` spends one boost from `wallets.boosts` for 30 minutes (`boost_ends_at`).

- Refused while one is running, or at zero (`no_boost`).
- Refused when nobody could see it: not onboarded (`onboarding_required`), no location or no approved
  photo (`not_visible`), or paused (`paused`). The boost is kept.
- Packs of 1, 5 or 10 are bought in the app (RevenueCat, `apply_purchase_event`). drafft tempo adds one
  a week (`private.credit_weekly_boosts`, see `20260924000011_weekly_boost.sql`).

## Pause

A paused profile (`profiles.paused`, set by the app) is frozen until it resumes:

- **The owner** gets `paused` from `discover`, `swipe`, `undo_last_swipe`, `start_boost` and every session
  action. Swipes and sessions are guarded at the table (triggers), so no path gets around it. Chats turn
  read-only: `db-events` bans the person in Stream on `profile.paused` and lifts the ban on resume;
  `stream-token` sets it again at launch, and `media-upload-url` refuses chat uploads (403 `paused`).
  Reading, editing the profile, blocking, reporting, unmatching and deleting the account still work.
  An account on hold from the team (`moderation`) also can't report, add profile media or register a push
  token (`moderated`); it can still export its data and delete the account.
- **Everyone else**: the person leaves decks and Likes tabs, and a swipe on them fails with `not_found`.
  Their matches and chats stay; they can still be written to.

## Blocks and reports

Blocking hides both people from each other everywhere (deck, Likes, chats) and ends their match. A
report always blocks too. Unblocking puts the person back in the blocker's deck (their old swipe is
forgotten); the old chat stays closed.

Reports need an onboarded account with no hold, and at most 10 in 24 hours per person (`report_limit`).
Someone reported as underage, or by 3 different people in 30 days, is held for review at once; only
reports from onboarded accounts with no hold count toward that.

## Errors

Errors come back from PostgREST with a stable code in `hint`.

| Code | From | Meaning |
| --- | --- | --- |
| `location_required` | `discover` | No location on file: ask for it, then `set_location` |
| `onboarding_required` | `discover`, `swipe`, `undo_last_swipe`, `start_boost`, `report_user` | The caller hasn't finished onboarding |
| `moderated` | `discover`, `swipe`, `undo_last_swipe`, `start_boost`, sessions, `report_user`, `add_profile_media`, `register_push_token` | The caller's account is on hold |
| `paused` | `discover`, `swipe`, `undo_last_swipe`, `start_boost`, sessions | The caller's profile is paused |
| `not_found` | `swipe` | Target unavailable: not onboarded, paused, or blocked |
| `not_eligible` | `swipe` | Like refused: the person is under 18, or their preferences leave the caller out |
| `already_swiped` | `swipe` | This person was swiped already |
| `daily_like_limit` | `swipe` | 20 likes in the last 24 hours (free accounts) |
| `no_super_likes` | `swipe` | No super like left |
| `cannot_undo` | `undo_last_swipe` | Nothing to undo: none, older than 10 minutes, or it made a match |
| `no_boost` | `start_boost` | None left, or one is running |
| `not_visible` | `start_boost` | Nobody would see it: no location or photo |
| `report_limit` | `report_user` | 10 reports in the last 24 hours |

## Performance

`scripts/bench.sql`: 50,000 profiles in Île-de-France, a viewer with 2,000 past swipes, warm cache,
database time only.

| Query | Time |
| --- | --- |
| `discover`, 10 km | ~3 ms |
| `discover`, any distance, 2 sports, age 25-35 | ~55 ms |
| `discover`, 2 km, a rare sport, age 40-41 (almost nobody matches) | ~9 ms |

Candidates come from `private.nearby_candidates`: a walk of the location index, nearest first, that
stops once it has `2 × p_limit` eligible people, or at the edge of the radius. Its cost follows how far
it has to walk, not how many people live nearby:

- **Pool size.** Each extra candidate walks further. With narrow filters (1 % of people eligible),
  going from 1× to 2× the batch took the any-distance query from ~25 to ~40 ms, and 4× to ~75 ms.
- **Forced index walk.** PostGIS underestimates how many people a radius holds (5 estimated, 11,000
  real at 10 km), so with a `LIMIT` the planner prefers to fetch the whole radius and sort it: 0.5 s
  instead of 3 ms. `nearby_candidates` runs with `enable_sort = off`, for its own two queries only, which
  leaves the index walk as the only plan.
- **Radius as an index condition.** With a distance limit, `st_dwithin` bounds the walk, so a filter
  nobody matches stops at the radius (~9 ms) instead of walking every profile (~190 ms).

Re-run `scripts/bench.sql` after touching `discover`, `nearby_candidates` or `eligible`.

## Known limits

- **A pass is forever.** Passed people never come back, so a small city runs out of cards. Recycling
  passes after some weeks would need `swipe` to overwrite old passes.
- **Super likes follow the filters.** A super like from someone outside the viewer's distance or age
  range doesn't reach the deck, only the Likes tab.
- **The score is local.** It only reorders the nearest `2 × p_limit` eligible people (plus super likers
  and boosts). A great match 20 km away waits until closer people have been swiped.
- **Who liked me is not gated.** `liked_me` returns identities to every account (see `TODO.md`).
