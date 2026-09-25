#!/usr/bin/env bash
# Pull request gate for supabase/migrations, against the base branch:
#  - a migration already on main is never edited, renamed or deleted (both projects already ran it);
#  - new files are named <14-digit timestamp>_<snake_case>.sql and sort after every existing one;
#  - destructive or table-locking statements need an explicit reason in the file:
#      -- migration-guard: allow <what> - <why>
#
#   scripts/ci/migrations-guard.sh origin/main
set -euo pipefail
base=${1:-origin/main}
dir=supabase/migrations
status=0
fail() { echo "error: $*"; status=1; }

while IFS=$'\t' read -r change path _; do
  case "$change" in
    A) ;;
    *) fail "$path: migrations already on main are immutable ($change). Add a new migration instead." ;;
  esac
done < <(git diff --name-status "$base"...HEAD -- "$dir" | grep -v '^A' || true)

latest=$(git ls-tree --name-only "$base" "$dir/" | xargs -n1 basename | sort | tail -n 1)
for path in $(git diff --name-only --diff-filter=A "$base"...HEAD -- "$dir"); do
  name=$(basename "$path")
  [[ "$name" =~ ^[0-9]{14}_[a-z0-9_]+\.sql$ ]] || fail "$name: expected <YYYYMMDDHHMMSS>_<snake_case>.sql"
  [[ "$name" > "$latest" ]] || fail "$name: sorts before $latest, already on main. Use a newer timestamp."

  sql=$(tr '[:upper:]' '[:lower:]' < "$path")
  check() { # pattern what
    if grep -qE "$1" <<<"$sql" && ! grep -qE "migration-guard: allow $2" <<<"$sql"; then
      fail "$name: $2. Add '-- migration-guard: allow $2 - <why>' if it's intended."
    fi
  }
  check '\bdrop[[:space:]]+(table|column|schema|type)\b' "destructive drop"
  check '\btruncate\b' "destructive drop"
  check 'alter[[:space:]]+table[^;]*alter[[:space:]]+column[^;]*[[:space:]]type[[:space:]]' "table rewrite"
  check 'alter[[:space:]]+table[^;]*set[[:space:]]+not[[:space:]]+null' "table rewrite"
  check 'disable[[:space:]]+row[[:space:]]+level[[:space:]]+security' "rls off"
  check 'grant[^;]*to[[:space:]]+(anon|public)\b' "anon grant"
  # Every new public table must turn RLS on in the same migration.
  for table in $(grep -oE 'create[[:space:]]+table[[:space:]]+(if[[:space:]]+not[[:space:]]+exists[[:space:]]+)?public\.[a-z0-9_]+' <<<"$sql" | awk '{print $NF}'); do
    grep -qE "alter[[:space:]]+table[[:space:]]+${table//./\\.}[[:space:]]+enable[[:space:]]+row[[:space:]]+level[[:space:]]+security" <<<"$sql" \
      || fail "$name: $table is created without 'enable row level security'"
  done
done

[ $status -eq 0 ] && echo "migrations-guard: clean."
exit $status
