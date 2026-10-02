<!--
Title: type(scope): lowercase description, no final period. It becomes the squash commit on staging.
  types: feat, fix, docs, style, refactor, test, chore. `type!:` for a breaking change.
Base: staging. Never main (main only moves through the release workflow).
No AI attribution line in the description or in any commit (CI refuses it, scripts/ci/pr_check.sh).
Delete these comments and any section that doesn't apply.
-->

## Summary

<!-- What changes for the person using drafft, in two or three sentences. Then why. -->

## Changes

<!-- The main changes, one line each, with the types or files that carry them. -->

-

## Testing

<!-- What you ran and what you saw. Say what you did not run. -->

- [ ] `deno fmt --check` and `deno lint` on `supabase/functions` and `scripts`
- [ ] `deno check` and `deno test` (functions), `deno check scripts/*.ts`
- [ ] `supabase test db` and the advisors check
- [ ] Run against staging (only what the user asked for), steps:
  1.

## Notes

- **Telemetry:** <!-- flows the apps must track (events: drafft-ios/docs/telemetry.md), errors and alerts added, no personal data in logs, or "none, because ..." -->
- **Wording:** <!-- strings added or changed in the 7 languages after WORDING.md section 10, or "no user-facing text" -->
- **Privacy:** <!-- new personal data, third party or retention change (legal pages in drafft-web), or "none" -->
- **Companion pull requests:** <!-- the other drafft repositories, or "none" -->
- **Migrations:** <!-- new migration files (staging migrations are immutable), or "none" -->
- **Breaking change:** <!-- what a client or the backend must do, or "none" -->
