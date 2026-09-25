# Commit Rules

## Format (MANDATORY)

```
type(scope): description
```

- **ONE LINE ONLY** - Multiline commits are forbidden
- **Types**: feat, fix, docs, style, refactor, test, chore
- **Scope**: Required for app-specific changes (web, mobile, shared, supabase)
- **Description**: Lowercase, no period, imperative mood
- **Start with a verb**: add, fix, update, remove, configure, refactor, etc. Never a bare noun list

## Examples

```
feat(auth): add PIN verification flow
fix(ui): resolve button alignment issue
refactor(services): extract user profile logic
chore(deps): update dependency X to v5
docs(readme): add setup instructions
test(auth): add login service tests
style(components): apply consistent spacing
```

## Branch Naming

| Prefix    | Usage               |
| --------- | ------------------- |
| `feat/`   | New features        |
| `fix/`    | Bug fixes           |
| `chore/`  | Maintenance         |
| `hotfix/` | Production critical |

## Pre-commit Hooks (ABSOLUTE)

- **ALL** commits must pass `pnpm verify`
- **NEVER** use `--no-verify`
- **NEVER** bypass hooks for any reason
- If hooks fail → fix the issue, don't skip it

## Attribution

- **NEVER** add `Co-Authored-By` trailers to commits
- All commits must appear as authored solely by the user
- Do not add any attribution lines for Claude or any AI tool

## Commit Content

- One logical change per commit
- Atomic commits that build independently
- No WIP commits on main branch
- Never commit sensitive data (.env, credentials)
