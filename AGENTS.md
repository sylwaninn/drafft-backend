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

Never write, regenerate or overwrite them either, `supabase/functions/.env.local` above all: it is the
user's own (a dedicated Resend key, `EMAIL_REAL`, `SMS_REAL`). `scripts/local-env.sh` only creates it when
it is missing: never run it when it exists, never give it an option that rewrites it. To change a local
setting, tell the user which line to edit.

## Local stack: real emails, fragile restarts

- **The local functions may send for real.** The user serves them with
  `supabase functions serve --env-file supabase/functions/.env.local`, where `EMAIL_REAL=true` can be set:
  emails then go out through Resend, not to Mailpit. Never trigger an email- or SMS-sending flow locally
  with made-up addresses or numbers. To look at an email, render it from your own Deno process with
  `MAILPIT_URL=http://127.0.0.1:55424` and `EMAIL_REAL` unset.
- **Test mutations on throwaway accounts only**: the Drafft Local apps and sophros use this same database.
- **Avoid restarting the stack.** `supabase stop && supabase start` kills the user's `functions serve`
  (the default runtime then lacks `EMAIL_FROM` and the rest). If a restart is needed (a function change in
  `config.toml`), tell the user to start the serve command again.
- **Storage version.** The local database's storage schema was migrated by storage-api v1.77.5; the CLI
  starts an older one unless `supabase/.temp/storage-version` (gitignored) says `v1.77.5`, and every
  upload then fails (500, `42P10`). Keep that file.

## User-facing text: WORDING.md first (priority rule)

Before writing or changing any text people receive (push, email, SMS, support replies, moderation
notices, product names, error sentences, in any of the 7 languages), read and apply
[WORDING.md](WORDING.md), then run its review checklist (section 10). The `wording` skill (`.claude/skills/wording/`) walks through it. Never write "plan" in any sense or language, and never
present a match as turning into something. This file is shared with drafft-ios (the
reference), drafft-android and drafft-web: see "Shared docs" before changing it.

## Working with the user

- **Rules live in this repository, never in an agent's memory.** A rule the user gives (design, copy,
  product, way of working) goes into the document it belongs to, in the same change: DESIGN.md,
  PRODUCT.md, this file, or WORDING.md (in drafft-ios, its source). Never save it to Claude Code's auto
  memory: a cloud session, another machine or another agent would never see it.
- **Industry-grade solutions.** Every fix or feature takes the robust, secure, scalable solution the
  industry already uses (proven libraries and patterns: idempotency keys, retries with backoff,
  dead-letter queues and redrive, circuit breakers, stale-while-revalidate), never a quick patch.
  Challenge it before presenting it: name the pattern, its failure modes and how they are covered.
- **Always live** (the apps' PRODUCT.md principle 7): any state a person can see (wallet, holds, photo
  decisions, matches, sessions, sophros counters) emits a Realtime event on `user:<id>` when it changes,
  a trigger on the table being the robust default, so the apps never wait for a relaunch.
- **Photos go public only on Save, enforced here.** A picked photo is a draft: uploaded and moderated, but
  the card, the portrait and Discover are built from published media only. Unsaved drafts are deleted,
  and a server purge covers an app killed mid-edit.
- **sophros capabilities start here**: an `admin_*` function with its role check (`private.staff`) and
  its audit line (`private.admin_audit`), then the page in drafft-sophros.
- **Reviews run in depth, never trimmed.** A review (`/pr-review-toolkit:review-pr`, a pull request
  audit) uses every applicable specialist agent on each pull request (code-reviewer,
  silent-failure-hunter, pr-test-analyzer, comment-analyzer, type-design-analyzer, then code-simplifier).
  Batch by repository if needed; never drop an aspect to save agents.
- **Don't wait for CI or deploys.** Start the run, look at its status once if useful, report and move on.
  Never block on `gh run watch`.

## Repository rules

Everything an agent needs is in this repository: this file, the docs it links, and `.claude/` (settings,
git guard, skills). Claude Code loads the same files on this machine and on the web.

### Branches and commits

- Never commit on `main` and `staging`. Branch from a fresh `origin/staging` (`git fetch origin` first), named
  `feat/`, `fix/`, `chore/`, `docs/` or `hotfix/` + a short kebab-case name.
- Commit messages: `type(scope): description`, one line, no body, no trailers. Types: feat, fix, docs,
  style, refactor, test, chore. Scope (required): `supabase` (`cloudflare` for the Workers, `ci` for workflows). The description is lowercase,
  imperative, starts with a verb and has no final period. Example: `fix(supabase): keep the wallet row on refund`.
- Commits are authored by the user only: never a `Co-Authored-By` or any AI attribution line
  (`.claude/settings.json` turns Claude Code's off; the `commit-msg` hook and CI refuse them).
- One logical change per commit; every commit passes verify. Never `--no-verify`.
- Enforcement: the git hooks in `.agents/git-hooks/` (`git config core.hooksPath .agents/git-hooks`,
  which `.claude/settings.json` runs at the start of every session) and, for Claude Code,
  `.claude/hooks/guard-git.py` (commits and pushes to `main` and `staging`, deleting them, `--no-verify`). If a hook
  refuses, change the approach; never work around it.

### Pull requests and releases

- Open them with the `create-pr` skill (`.claude/skills/create-pr/`), into `staging`. Title in
  conventional commit format, English, 70 characters at most (it becomes the squash commit and feeds
  the release version: `type!:` major, any `feat` minor, else patch). Every section of the body filled,
  no AI attribution. Squash-merge.
- Never merge a pull request whose checks are red or still running, never with admin rights.
- A merge into `staging` deploys staging (`backend.yml`). A release (Actions > release, started by hand on GitHub) fast-forwards `main` to `staging`, tags `vX.Y.Z`, and `backend.yml` deploys that tag to production. Roll back with Run workflow on an older tag (or a pushed `v*` tag).
- Agents never start a release or a deploy unless the user asks for it in the current request, and
  never tag by hand.

### Secrets

Never open, print, copy, search or summarize `.env*` files (`.env.example` is safe), `.dev.vars`
(`.dev.vars.example` is safe), keys, `google-services.json` or anything in `~/Secrets/`, by any means.
Run the CLI that consumes them without showing them, and only when the user asks: it writes to a remote
project. Never write, regenerate or overwrite a user's `.env.local`. `.claude/settings.json` denies the
reads.

### Environments

Apps an agent installs or launches always target the local Supabase. Never build, install, deploy or run
mutations against staging or production unless the user asks for that environment in the current
request. Compile-only checks are the exception.

### Work that spans repositories

A product feature usually runs backend, then iOS, then Android (then the website for legal or marketing
copy): one session and one pull request per repository, backend first since the apps call its RPCs and
functions. iOS is the reference; Android ports it with the same names, behaviour and strings. The first
pull request states the contract (RPCs, payloads, event names) and the next ones link it. Another
repository is read on GitHub (`gh repo clone sylwaninn/<repo>` into a temporary folder), never edited
from here, except the shared docs below when the user agrees.

### Shared docs

`WORDING.md` (in drafft-ios, drafft-android, drafft-backend and drafft-web) and `DESIGN.md` (in drafft-ios
and drafft-android) are one document kept identical in each repository; drafft-ios holds the reference.
**After changing either one here, ask the user whether the change goes to the other repositories' copies.**
If yes, make the identical change in each, one pull request per repository (`gh repo clone
sylwaninn/<repo>` into a temporary folder, a branch from its base, the `create-pr` skill), and link the
pull requests to each other. Locally, drafft-ios's `scripts/sync-shared.sh` writes the copies from
drafft-ios, and `--check` lists those that differ.

### This repository

`staging` (the default branch) takes every pull request; `main` is production and only moves through
the release workflow (Actions > release: staging's new commits onto `main`, a `vX.Y.Z` tag and a GitHub
release, see `scripts/ci/release.sh`). A merge into `staging` deploys staging; the release deploys its
tag to production. "Verify" in these rules
(`pnpm verify`) means, in this repository:

```sh
deno fmt --check supabase/functions scripts && deno lint supabase/functions scripts \
  && (cd supabase/functions && deno check ./*/index.ts && deno test --allow-env --allow-read=.,../../WORDING.md) \
  && deno check scripts/*.ts \
  && supabase test db && supabase db advisors --local --level info -o json | python3 scripts/ci/advisors.py
```

CI (`.github/workflows/`) runs the same, plus shellcheck, actionlint, gitleaks, a schema lint, the
migration guard (`scripts/ci/migrations-guard.sh`: migrations on staging are immutable, destructive or
locking statements need `-- migration-guard: allow <what> - <why>`), and after each deploy and daily
the drift check between the repository, staging and production (`scripts/ci/env-parity.sh`). A new
advisor finding fails the build: fix it, or accept it in `supabase/advisors-baseline.json` with a reason.
