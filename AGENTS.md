# Instructions for AI agents

## Secrets: hard rule

Never open, read, print, copy, search, summarize or upload these files, by any means (file tools, shell
commands such as cat/grep/sed/base64, scripts, or asking a tool to echo them):

- `supabase/.env`
- `supabase/functions/.env`
- `supabase/functions/.env.production`
- any other `.env`, `.env.production`, `.env.local` or `.env.*.local`

They hold production credentials (R2, Stream, APNs, auth providers). To use them, run the CLI that consumes
them without displaying them, e.g. `supabase secrets set --env-file supabase/functions/.env.production`.
If a task seems to need a value from them, ask the human instead. The `.env.example` files are safe to read.

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
(cd supabase/functions && deno check */index.ts) && deno check scripts/*.ts && supabase test db
```

@.agents/rules/commits.md
@.agents/rules/github.md
