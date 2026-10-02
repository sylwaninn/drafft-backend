#!/usr/bin/env bash
# Checks a pull request before it can land: the rules the git hooks enforce locally, applied to what
# reaches GitHub (a commit made without the hooks, a pull request opened from the web, a body pasted
# from a tool). Run by .github/workflows/pr.yml on every pull request, the same script in every repository.
#
#   - base: never main (main only moves through the release workflow, scripts/ci/release.sh), except in
#     drafft-web, which has no staging: its pr.yml sets ALLOW_MAIN_BASE=true;
#   - title: `type(scope): description`, lowercase, no final period: it becomes the squash commit;
#   - body: not empty, no AI attribution line;
#   - commits: authored by an allowed address, no Co-Authored-By or AI attribution in any message;
#   - signatures: unverified commits are listed (a warning, an error with REQUIRE_SIGNED=true).
#
# Needs BASE_REF, BASE_SHA, HEAD_SHA, PR_TITLE, PR_BODY and ALLOWED_EMAILS (space-separated).
# ALLOW_MAIN_BASE=true lets pull requests target main (drafft-web only).
# With GH_TOKEN, GITHUB_REPOSITORY and PR_NUMBER it also reads GitHub's signature verification.
set -euo pipefail

: "${BASE_REF:?}" "${BASE_SHA:?}" "${HEAD_SHA:?}" "${PR_TITLE:?}" "${ALLOWED_EMAILS:?}"
PR_BODY=${PR_BODY:-}
REQUIRE_SIGNED=${REQUIRE_SIGNED:-false}
ALLOW_MAIN_BASE=${ALLOW_MAIN_BASE:-false}
# The squash commit's committer when a pull request is merged or updated from GitHub's interface.
GITHUB_COMMITTER="noreply@github.com"
# Attribution lines tools add to commits and pull requests. Naming a tool in prose stays allowed.
ATTRIBUTION='co-authored-by:|generated (with|by) \[?(claude|copilot|chatgpt|cursor|codex|gemini)|claude\.ai/code|claude\.com/claude-code|@anthropic\.com|claude-session:'
TITLE='^(feat|fix|docs|style|refactor|test|chore)(\([a-z0-9-]+\))?!?: [a-z].*[^.]$'

errors=0
error() {
  echo "::error::$*"
  errors=$((errors + 1))
}
allowed() {
  case " $ALLOWED_EMAILS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

[ "$BASE_REF" != main ] || [ "$ALLOW_MAIN_BASE" = true ] ||
  error "This pull request targets main. Every pull request goes into staging; main only moves through the release workflow."

grep -qE "$TITLE" <<<"$PR_TITLE" ||
  error "Title \"$PR_TITLE\" isn't type(scope): lowercase description without a final period (it becomes the squash commit)."

[ -n "$(tr -d '[:space:]' <<<"$PR_BODY")" ] || error "The description is empty: fill in .github/pull_request_template.md."
if grep -inE "$ATTRIBUTION" <<<"$PR_BODY" >/dev/null; then
  error "The description carries an attribution line: $(grep -ioE "$ATTRIBUTION" <<<"$PR_BODY" | head -n 1)."
fi

commits=$(git rev-list --no-merges "$BASE_SHA..$HEAD_SHA")
[ -n "$commits" ] || error "No commit between $BASE_REF and the head."
for sha in $commits; do
  short=${sha::7}
  author=$(git log -1 --format=%ae "$sha")
  committer=$(git log -1 --format=%ce "$sha")
  allowed "$author" || error "$short is authored by $author, not an allowed address (git config user.email)."
  allowed "$committer" || [ "$committer" = "$GITHUB_COMMITTER" ] ||
    error "$short is committed by $committer, not an allowed address."
  if git log -1 --format=%B "$sha" | grep -iqE "$ATTRIBUTION"; then
    error "$short's message carries an attribution line: $(git log -1 --format=%B "$sha" | grep -ioE "$ATTRIBUTION" | head -n 1)."
  fi
done

if [ -n "${GH_TOKEN:-}" ] && [ -n "${PR_NUMBER:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  unsigned=$(gh api --paginate "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/commits" \
    --jq '.[] | select(.commit.verification.verified | not) | "\(.sha[0:7]) (\(.commit.verification.reason))"')
  if [ -n "$unsigned" ]; then
    message="Unverified commits (set up commit signing, see README > Contributing): $(tr '\n' ' ' <<<"$unsigned")"
    if [ "$REQUIRE_SIGNED" = true ]; then error "$message"; else echo "::warning::$message"; fi
  fi
fi

[ "$errors" -eq 0 ] || exit 1
echo "Pull request checks passed ($(wc -w <<<"$commits") commit(s))."
