# Instructions for AI agents

## Secrets: hard rule

Never open, read, print, copy, search, summarize or upload these files, by any means (file tools, shell
commands such as cat/grep/sed/base64, scripts, or asking a tool to echo them):

- `supabase/.env`
- `supabase/functions/.env`
- `supabase/functions/.env.production`
- any other `.env`, `.env.production`, `.env.local` or `.env.*.local`

They hold production credentials (R2, Stream, APNs, auth providers). To use them, run the CLI that consumes
them without displaying them, always naming the project, e.g.
`supabase secrets set --project-ref <ref> --env-file supabase/functions/.env.<env>` (refs in
`scripts/deploy.sh`; the CLI stays linked to staging, so without `--project-ref` it writes there), and only
when the human asks for it: it writes to a remote project. If a task seems to need a value from them, ask the
human instead. The `.env.example` files are safe to read.

## Rules for every agent

Read these before committing or opening a pull request. They live in `.agents/` so any agent can use
them; Claude Code loads them through `CLAUDE.md`.

- Commits and branches: [.agents/rules/commits.md](.agents/rules/commits.md)
- GitHub (pull requests, comments): [.agents/rules/github.md](.agents/rules/github.md)
- Skills: `.agents/skills/` (`create-pr`, `technical-writer`)
- Git hooks that enforce them for everyone, agents and humans (`.agents/git-hooks/`): `commit-msg`
  (format, one line, no Co-Authored-By) and `pre-push` (no push to `main`). Enable once per clone:
  `git config core.hooksPath .agents/git-hooks`

`main` is protected by convention: work on a branch, open a pull request. "Verify" in these rules
(`pnpm verify`) means, in this repository:

```sh
deno fmt --check supabase/functions scripts && deno lint supabase/functions scripts \
  && (cd supabase/functions && deno check ./*/index.ts && deno test --allow-env --allow-read=.) \
  && deno check scripts/*.ts \
  && supabase test db && supabase db advisors --local --level info -o json | python3 scripts/ci/advisors.py
```

CI (`.github/workflows/`) runs the same, plus shellcheck, actionlint, gitleaks, a schema lint, the
migration guard (`scripts/ci/migrations-guard.sh`: migrations on main are immutable, destructive or
locking statements need `-- migration-guard: allow <what> - <why>`), and after each deploy and daily
the drift check between the repository, staging and production (`scripts/ci/env-parity.sh`). A new
advisor finding fails the build: fix it, or accept it in `supabase/advisors-baseline.json` with a reason.

@.agents/rules/commits.md
@.agents/rules/github.md
