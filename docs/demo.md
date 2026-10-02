# Demo people

100 complete, onboarded demo profiles spread over Lyon and its suburbs, to try the app with a full Discover,
and a script that makes them act towards a real account to see its notifications. **Staging and local only**:
`scripts/demo/guard.ts` stops both scripts before any write unless the target is `staging` or `local`, the env
file is staging's (`R2_BUCKET=drafft-media-staging`, no variable naming the production project), and the
database itself says it is staging (its `edge_functions_url` Vault secret names the staging ref) or local.

```sh
E=supabase/functions/.env.staging
deno run -A --env-file=$E scripts/demo-profiles.ts staging seed [count]   # creates who is missing (100 by default)
deno run -A --env-file=$E scripts/demo-profiles.ts staging refresh        # at least monthly: Discover hides 30 days idle
deno run -A --env-file=$E scripts/demo-profiles.ts staging purge          # deletes them, photos included
deno run -A --env-file=$E scripts/demo-profiles.ts staging thumbhash      # ThumbHash for photos seeded without one (idempotent)
deno run -A --env-file=$E scripts/demo-interact.ts staging <email> likes|superlikes|matches|messages|sessions [n]
deno run -A --env-file=$E scripts/demo-interact.ts staging <email> replies|reactions|accept|scenario
```

- Accounts `demoNNN@drafft.test` (reserved domain, never emailed), confirmed email and fictional phone
  (+33 6 39 98), no password. People are written by hand in `scripts/demo/personas.ts`; they are inserted
  straight into the database through the Management API (`supabase db query --linked`, no Supabase key).
- Photos: five Picsum pictures (Unsplash licence, no faces) reused across everyone, under `u/<id>/demo/` in
  `drafft-media-staging`, inserted approved (no moderation run), each with its ThumbHash (jpeg-js + thumbhash,
  from the file itself, as the app computes it): the placeholder of cards and of blurred likes. Setting it
  rebuilds the person's card (`profile_media_card` trigger).
- `demo-interact.ts` runs the app's RPCs (`swipe`, `propose_session`, `respond_session`) as the demo person, by
  setting their id as the JWT subject, so rules, events and pushes are the real ones; chat goes through Stream
  as them, with Stream's own message push (both apps).
- Discover's preferences are mutual: an account only sees the demo people whose own preferences include it.
