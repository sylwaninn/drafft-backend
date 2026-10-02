---
name: create-pr
description: Create a feature branch, scoped commits and a pull request in drafft-backend, following this repository's rules (AGENTS.md, "Repository rules"). Use for any "open a PR", "push this", "create a pull request".
allowed-tools: Bash(git:*), Bash(gh:*), Bash(pnpm:*), Bash(./gradlew:*), Bash(python3 scripts/*), Bash(deno:*), Bash(supabase:*), Bash(xcodegen:*), Bash(xcodebuild:*), Bash(swiftlint:*), Read, Grep, Glob
argument-hint: [branch-name] [pr-title]
---

# Create a pull request

Rules: `AGENTS.md`, section "Repository rules". Base branch: `staging`.

## 1. Branch

If on `main` or `staging`, create a branch from an up-to-date base:
`git fetch origin && git switch -c <prefix>/<name> origin/staging` (`git switch -c` keeps the
uncommitted work). Prefixes: `feat/`, `fix/`, `chore/`, `docs/`, `hotfix/`, then short kebab-case.

## 2. Scoped commits

Review `git diff` and `git status`. Split the work into logical commits (foundations first): feature
logic, UI, i18n, refactors, config/CI, fixes. For each:

1. `git add <specific files>` (never `git add .` / `-A`); nothing secret staged.
2. `git commit -m "type(scope): description"`: one line, scope `supabase` (`cloudflare` for the Workers, `ci` for workflows), no trailers.
3. If a hook fails, fix the cause and commit again. Never `--no-verify`.

## 3. Verify

Run the block in `AGENTS.md` (deno fmt, lint, check and test, `supabase test db`, advisors). Zero errors. If a tool is missing (Android SDK, local Supabase not running,
no macOS on the web), run the rest and say in the pull request what was left to CI.

## 4. Docs, legal, parity

- **README / AGENTS.md**: update them in the same pull request when env vars, build settings, scripts,
  CI gates, modules or dependencies change (a `docs(...)` commit).
- **Legal pages** (privacy, terms) live in drafft-web (`legal/`). If the change adds a third-party
  service, new personal data, a new permission, or changes retention or deletion, flag it in the pull
  request ("Legal pages in drafft-web need an update: ...") and tell the user.
- **Telemetry**: the pull request's Notes say what was added, or "Telemetry: none, because ...".
- **User-facing text**: the `wording` skill was applied.

- **Migrations** on `staging` are immutable (it deploys them).

## 5. Push and open

```bash
git push -u origin <branch>
gh pr create --base staging --title "<type(scope): description>" --body "$(cat <<'EOF'
## Summary

<1-2 sentences: what and why>

## Changes

- <change>

## Testing

- <what was run, and what was left to CI>

## Notes

<legal flags, linked pull requests in other repositories, deploy steps, "Telemetry: ...", or "None">
EOF
)"
```

English, every section filled ("None" when empty), no AI attribution line.

## Returns

The pull request URL, the branch, the commits.
