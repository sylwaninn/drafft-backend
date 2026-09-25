---
name: create-pr
description: Create and push a new feature branch with a pull request following project conventions
allowed-tools: Bash(git:*), Bash(gh:*), Bash(pnpm:*), Read, Grep, Glob, Skill(technical-writer)
argument-hint: [branch-name] [pr-title]
---

# Create Pull Request

Automate the creation of a feature branch, commits, and pull request following all project conventions.

## Current State

- Current branch: !`git rev-parse --abbrev-ref HEAD`
- Git status: !`git status --short`
- Uncommitted changes: !`git diff --stat`

## Arguments

- `$ARGUMENTS[0]`: Branch name (e.g., `feat/my-feature` or just `my-feature`)
- `$ARGUMENTS[1]`: PR title (optional, will be generated from commits if not provided)

## Workflow Steps

### 1. Branch Creation

If not already on a feature branch:

- Create a new branch following naming conventions:
  - `feat/feature-name` for new features
  - `fix/bug-description` for bug fixes
  - `chore/maintenance-task` for maintenance
  - `hotfix/critical-fix` for production hotfixes
- Checkout the new branch

### 2. Staged Changes Review

- Review all staged and unstaged changes with `git diff`
- **Identify logical groups of changes for separate commits** (see step 3)
- Ensure no sensitive files are staged (.env, credentials, etc.)

### 3. Create Scoped Commits (MANDATORY: multiple commits)

**NEVER create a single monolithic commit for all changes.** Always split changes into multiple scoped commits, each representing one logical unit of work.

**How to split commits:**

1. Analyze all changed files and group them by concern:
   - Feature logic (new components, services, hooks)
   - UI/styling changes (CSS, layout, design tokens)
   - i18n/translations (locale JSON files)
   - Refactoring (renaming, extracting, restructuring existing code)
   - Configuration (build, linting, CI)
   - Bug fixes
2. Each group becomes its own commit
3. Order commits logically: foundational changes first, dependent changes after

**Example split for a profile modal rework:**

```
refactor(web): remove size prop from Button component
style(web): add frosted-header utility and float animation
feat(web): add account deletion flow
feat(web): rework profile modal as single scrollable page
chore(web): update profile i18n keys for all locales
```

**For each commit:**

1. Stage only the relevant files: `git add <specific-files>` (never `git add .` or `git add -A`)
2. Create commit following **MANDATORY** rules:
   - Format: `type(scope): description`
   - **ONE LINE ONLY**, multiline commits are forbidden
   - Types: feat, fix, docs, style, refactor, test, chore
   - Scope: required for app-specific changes (web, mobile, shared, supabase)
   - Description: lowercase, no period at end, start with a verb
   - Examples:
     - `feat(web): add PIN verification flow`
     - `fix(mobile): resolve button alignment issue`
     - `refactor(shared): extract user profile types`
     - `chore(web): update profile i18n keys for all locales`

3. **NEVER use `--no-verify`**, all commits must pass pre-commit hooks
4. If hooks fail, fix the issues and retry

### 4. Run Verification

Before pushing, ensure quality:

```bash
pnpm verify
```

This must pass with zero warnings/errors. Fix any issues before proceeding.

### 5. Update Documentation (if needed)

Before pushing, check whether the branch's changes require README updates. Compare all commits on the branch against main and look for:

- New or changed **environment variables** (`.env.example`, `import.meta.env`, `process.env`, `EXPO_PUBLIC_*`)
- New or changed **scripts** in any `package.json`
- New major **dependencies** added or removed
- New **top-level directories** under `src/`
- Changes to **build/deployment** config or **quality gates**

If any of these are detected, invoke `/technical-writer` to update the affected READMEs (root, web, mobile) before continuing. The documentation commit(s) should use the `docs` type (e.g., `docs: update README for new env vars`).

If none of the above apply, skip this step.

### 5b. Check Legal Pages (if needed)

If the PR introduces changes that affect legal obligations, check whether the legal pages (`apps/web/src/locales/*/pages.json`) need updating. Look for:

- New **third-party services** or SDKs added (e.g., analytics, crash reporting, payment providers)
- Changes to **data collection** (new personal data fields, new tracking events)
- Changes to **authentication** flow or required user information
- New **cookie** or local storage usage
- Changes to **data retention** or deletion behavior
- Changes to the **hosting infrastructure** (new providers)
- Addition of **paid features** or subscription model

If any of these are detected, update the relevant sections in `apps/web/src/locales/*/pages.json` (all 5 locales: fr, en-GB, es-ES, de, pt-BR) and bump the `lastUpdated` date. The legal pages commit should use `chore(web): update legal pages` format.

If none of the above apply, skip this step.

### 5c. Detect Native Mobile Changes (MANDATORY for mobile scope)

If any commit on the branch touches `apps/mobile/`, you MUST check whether the changes require a native rebuild. The `[native]` flag in the PR title controls whether the CI triggers an OTA update or a full native version bump.

**Run this detection by diffing the branch against main:**

```bash
git diff main...HEAD --name-only
```

**The PR title MUST include `[native]` if ANY of these conditions are true:**

1. **Native directories changed:**
   - `apps/mobile/ios/**`
   - `apps/mobile/android/**`
   - `apps/mobile/plugins/**`

2. **Expo plugins changed in `app.config.ts`:**
   - Lines added/removed/modified inside the `plugins: [...]` array
   - Check with: `git diff main...HEAD -- apps/mobile/app.config.ts` and look for changes in plugin entries

3. **Native-impacting fields changed in `app.config.ts`:**
   - `bundleIdentifier`, `package` (Android package name)
   - `icon`, `splash`, `adaptiveIcon` (requires rebuild for native assets)
   - `orientation`, `newArchEnabled`
   - `infoPlist`, `entitlements`
   - Any field inside `ios: { ... }` or `android: { ... }` blocks (except `buildNumber` and `versionCode` which are handled by the version workflow)

4. **New native dependencies added in `package.json`:**
   - Check `git diff main...HEAD -- apps/mobile/package.json` for new dependencies
   - Packages matching these patterns are native: `react-native-*`, `@react-native-*`, `@react-native-community/*`, `expo-*` (NEW additions only, not version bumps)
   - Use this heuristic: if a line was added in `"dependencies"` or `"devDependencies"` with a package name matching the above patterns, it is native

5. **EAS build config changed:**
   - `apps/mobile/eas.json`

**How to apply:**
- If native changes detected, append ` [native]` to the PR title
- Example: `feat(mobile): add camera support [native]`
- If mixed mobile+web PR with native mobile changes, still append `[native]`
- If only JS/TS changes in `apps/mobile/src/`, NO `[native]` needed

**Detection script (run in bash):**

```bash
NATIVE_CHANGES=false

# Check native directories
if git diff main...HEAD --name-only | grep -qE '^apps/mobile/(ios|android|plugins)/'; then
  NATIVE_CHANGES=true
fi

# Check app.config.ts for plugin/native config changes
if git diff main...HEAD -- apps/mobile/app.config.ts | grep -qE '^\+.*plugins|^\+.*bundleIdentifier|^\+.*package:|^\+.*infoPlist|^\+.*entitlements|^\+.*newArchEnabled|^\+.*orientation'; then
  NATIVE_CHANGES=true
fi

# Check for new native dependencies
if git diff main...HEAD -- apps/mobile/package.json | grep -qE '^\+\s*"(react-native-|@react-native|expo-)'; then
  NATIVE_CHANGES=true
fi

# Check EAS config
if git diff main...HEAD --name-only | grep -q '^apps/mobile/eas.json'; then
  NATIVE_CHANGES=true
fi

echo "Native changes detected: $NATIVE_CHANGES"
```

If `NATIVE_CHANGES=true`, the PR title MUST end with ` [native]`.

### 6. Push Branch

Push the branch to remote with tracking:

```bash
git push -u origin <branch-name>
```

### 7. Create Pull Request

**CRITICAL: You MUST use the EXACT template structure below. No exceptions.**

Use this exact command structure:

```bash
gh pr create --title "<title>" --body "$(cat <<'EOF'
## Type of Change

- [ ] ✨ New feature
- [ ] 🐛 Bug fix
- [ ] 📝 Documentation
- [ ] 🔧 Configuration
- [ ] 🤖 CI/CD
- [ ] ♻️ Refactor
- [ ] 🎨 Style

## Summary

<Brief description of changes - 1-2 sentences>

## Motivation

<Why are these changes needed? What problem do they solve?>

## Changes

### Main Changes

- <Change 1>
- <Change 2>

### Additional Changes

- <Change 1 or "None">

## Testing

### Prerequisites

<List any prerequisites or "None">

### Test Steps

1. <Step 1>
2. <Step 2>
3. <Expected result>

## Documentation

- [x] No documentation changes needed

## Breaking Changes

- [x] No breaking changes

## Checklist

- [x] All tests pass (`pnpm verify`)
- [x] TypeScript compiles without errors
- [x] No console warnings or errors introduced
- [x] Code follows project conventions
EOF
)"
```

**MANDATORY RULES:**

- The PR description MUST be written in **English**
- Check ONE or more types of change with `[x]`
- Fill ALL sections (use "None" or "N/A" if not applicable)
- Check all applicable items in Checklist
- Never skip or simplify this template

### 8. Update PR Details

After creation:

- Ensure title is concise and descriptive
- Fill all template sections appropriately
- Add relevant labels if applicable
- Request reviewers if needed

## Commit Message Examples

```
feat(auth): add biometric authentication support
fix(home): resolve application list refresh issue
refactor(ui): extract Button component from screens
chore(i18n): add missing French translations
docs(api): update authentication endpoints
style(components): apply consistent spacing
test(services): add user profile service tests
```

## PR Title Guidelines

- Keep under 70 characters
- Use imperative mood ("Add feature" not "Added feature")
- Be specific about what changes
- Include scope if helpful

Good: `feat(auth): add PIN code verification`
Bad: `Updated some auth stuff`

## Checklist Before PR

- [ ] Changes are split into multiple scoped commits (not one big commit)
- [ ] All commits follow conventional format
- [ ] No `--no-verify` was used
- [ ] `pnpm verify` passes
- [ ] READMEs updated if env vars, scripts, deps, or structure changed (via `/technical-writer`)
- [ ] Legal pages updated if new third-party services, data collection, or hosting changes
- [ ] Branch name follows conventions
- [ ] PR description is complete
- [ ] No sensitive data in commits

## Returns

- **pr_url**: The URL of the created pull request
- **branch**: The name of the feature branch
- **commits**: List of commits included in the PR
