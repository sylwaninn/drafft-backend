#!/usr/bin/env bash
# Next release tag from a pull request title (conventional commits) and the last v* tag.
#   type(scope)!: ...  or  BREAKING CHANGE  → major
#   feat(scope): ...                        → minor
#   any other type (fix, chore, refactor…)  → patch
# Usage: scripts/ci/next-version.sh "<title>" [last-tag]   (prints e.g. v1.2.0)
set -euo pipefail

title=${1:?Usage: $0 "<pull request title>" [last-tag]}
last=${2:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || echo v0.0.0)}

pattern='^(feat|fix|docs|style|refactor|perf|test|chore|ci|build|revert)(\([a-z0-9-]+\))?(!)?: .+'
if ! [[ $title =~ $pattern ]]; then
  echo "Not a conventional title: '$title' (expected type(scope): description)" >&2
  exit 65
fi
type=${BASH_REMATCH[1]}
breaking=${BASH_REMATCH[3]}

if ! [[ $last =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "Last tag isn't vX.Y.Z: '$last'" >&2
  exit 65
fi
major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} patch=${BASH_REMATCH[3]}

if [ -n "$breaking" ] || [[ $title == *"BREAKING CHANGE"* ]]; then
  echo "v$((major + 1)).0.0"
elif [ "$type" = feat ]; then
  echo "v$major.$((minor + 1)).0"
else
  echo "v$major.$minor.$((patch + 1))"
fi
