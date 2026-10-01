#!/usr/bin/env bash
# Releases staging to production: fast-forwards main to staging's head, tags that commit with the next
# version and publishes a GitHub release listing its pull requests. Run by .github/workflows/release.yml
# (Actions > release > Run workflow), never by hand.
#
#   - staging's head must have passed CI: the push run of $CI_WORKFLOW on that very commit is green;
#   - main only ever fast-forwards: a commit on main that staging lacks stops the release;
#   - version: `auto` reads the released commits (the squash-merged pull request titles): any `type!:`
#     or BREAKING CHANGE gives a major, any `feat` a minor, anything else a patch. `patch`, `minor`,
#     `major` or an exact `vX.Y.Z` override it. No tag yet: counts from v0.0.0.
#
# Usage: scripts/ci/release.sh [auto|patch|minor|major|vX.Y.Z]
# Needs GH_TOKEN (contents: write, actions: read), GITHUB_REPOSITORY and CI_WORKFLOW (e.g. ci.yml).
# Writes tag= and sha= to $GITHUB_OUTPUT, and a line to $GITHUB_STEP_SUMMARY.
set -euo pipefail

requested=${1:-auto}
: "${GH_TOKEN:?}" "${GITHUB_REPOSITORY:?}" "${CI_WORKFLOW:?}"
out=${GITHUB_OUTPUT:-/dev/null}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}

fail() {
  echo "::error::$*"
  exit 1
}

gh auth setup-git
git fetch -q --tags origin +refs/heads/main:refs/remotes/origin/main +refs/heads/staging:refs/remotes/origin/staging
sha=$(git rev-parse origin/staging)
main=$(git rev-parse origin/main)

[ "$sha" != "$main" ] || fail "Nothing to release: main is already staging's head (${sha::7})."
git merge-base --is-ancestor "$main" "$sha" ||
  fail "main has $(git rev-list --count "$sha..$main") commit(s) staging lacks (main only moves through this release): merge main into staging, with a merge commit and not a squash, then release."

run=$(gh run list -R "$GITHUB_REPOSITORY" --workflow "$CI_WORKFLOW" --commit "$sha" --event push --limit 1 \
  --json status,conclusion,url --jq '.[0] | "\(.status) \(.conclusion) \(.url)"')
case "$run" in
  "completed success "*) ;;
  "") fail "No $CI_WORKFLOW run for staging's head (${sha::7}) yet." ;;
  *) fail "$CI_WORKFLOW on staging's head (${sha::7}) isn't green: $run" ;;
esac

last=$(git tag --merged "$main" --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -n 1)
last=${last:-v0.0.0}
[[ $last =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || fail "Last tag isn't vX.Y.Z: $last"
major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} patch=${BASH_REMATCH[3]}

if [ "$requested" = auto ]; then
  subjects=$(git log --format=%s "$main..$sha")
  if grep -qE '^[a-z]+(\([a-z0-9-]+\))?!: ' <<<"$subjects" || git log --format=%B "$main..$sha" | grep -q 'BREAKING CHANGE'; then
    requested="major"
  elif grep -qE '^feat(\([a-z0-9-]+\))?: ' <<<"$subjects"; then
    requested="minor"
  else
    requested="patch"
  fi
fi
case "$requested" in
  major) tag="v$((major + 1)).0.0" ;;
  minor) tag="v$major.$((minor + 1)).0" ;;
  patch) tag="v$major.$minor.$((patch + 1))" ;;
  *)
    [[ $requested =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Version: auto, patch, minor, major or vX.Y.Z, not '$requested'."
    tag=$requested
    ;;
esac
[ "$(printf '%s\n%s\n' "$last" "$tag" | sort -V | tail -n 1)" = "$tag" ] && [ "$tag" != "$last" ] ||
  fail "$tag isn't above the last release, $last."
! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || fail "$tag already exists."

git tag "$tag" "$sha"
# One push for both: main and the tag land together or not at all.
git push --atomic origin "$sha:refs/heads/main" "refs/tags/$tag"
gh release create "$tag" -R "$GITHUB_REPOSITORY" --verify-tag --generate-notes --title "$tag"

echo "tag=$tag" >>"$out"
echo "sha=$sha" >>"$out"
echo "Released $tag (${sha::7}, after $last): main now matches staging. $(git rev-list --count "$main..$sha") commit(s)." >>"$summary"
