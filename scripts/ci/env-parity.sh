#!/usr/bin/env bash
# Drift between the repository, staging and production. Read only. Needs SUPABASE_ACCESS_TOKEN.
#  - both projects ran exactly the migrations in supabase/migrations (production may lag staging
#    only between a merge and the next release tag: pass --allow-prod-behind for that);
#  - both deploy the same Edge Functions as the repository;
#  - both have the same function secret names (values differ on purpose);
#  - both have the same database objects that migrations don't always own: extensions, event triggers
#    (dashboard toggles create some), public functions;
#  - neither has advisor findings the baseline doesn't accept.
#
#   scripts/ci/env-parity.sh [--allow-prod-behind]
set -euo pipefail
cd "$(dirname "$0")/../.."
PRODUCTION_REF=wrcpgnqwjmnirjfxpcux
STAGING_REF=rjlghcuspdtrmbimyioe
allow_behind=${1:-}
status=0
fail() { echo "error: $*"; status=1; }
quiet() { grep -vE '^(WARN: environment variable|A new version|We recommend|Initialising|Connecting)' || true; }

# Links one project; on failure, says why (the CLI's own message) instead of exiting silently.
link() { # env ref
  local out
  out=$(supabase link --project-ref "$2" 2>&1) && return
  echo "error: couldn't link the CLI to $1 ($2):" >&2
  printf '%s\n' "$out" | quiet >&2
  exit 1
}
# On every exit, errors included: leave the CLI linked to staging, never to production.
relink_staging() {
  supabase link --project-ref "$STAGING_REF" >/dev/null 2>&1 \
    || echo "warning: couldn't link the CLI back to staging: run supabase link --project-ref $STAGING_REF" >&2
}
trap relink_staging EXIT

repo_migrations=$(ls supabase/migrations | sed -E 's/_.*//' | sort)
repo_functions=$(find supabase/functions -mindepth 2 -maxdepth 2 -name index.ts | awk -F/ '{print $3}' | sort)

secrets_staging=""
secrets_production=""
schema_staging=""
schema_production=""
for env in staging production; do
  ref=$STAGING_REF; [ $env = production ] && ref=$PRODUCTION_REF
  link "$env" "$ref"

  ran=$(supabase db query --linked "select version from supabase_migrations.schema_migrations order by 1" -o csv 2>/dev/null | tail -n +2 | sort)
  missing=$(comm -23 <(echo "$repo_migrations") <(echo "$ran"))
  extra=$(comm -13 <(echo "$repo_migrations") <(echo "$ran"))
  [ -z "$extra" ] || fail "$env ran migrations the repository doesn't have: $(echo $extra)"
  if [ -n "$missing" ]; then
    if [ $env = production ] && [ "$allow_behind" = --allow-prod-behind ]; then
      echo "note: production hasn't run yet: $(echo $missing)"
    else
      fail "$env hasn't run: $(echo $missing)"
    fi
  fi

  deployed=$(supabase functions list --project-ref "$ref" -o json 2>/dev/null | python3 -c 'import json,sys; print("\n".join(sorted(f["slug"] for f in json.load(sys.stdin))))')
  [ "$deployed" = "$repo_functions" ] || fail "$env functions differ from the repository: $(diff <(echo "$repo_functions") <(echo "$deployed") | grep '^[<>]' | tr '\n' ' ')"

  names=$(supabase secrets list --project-ref "$ref" -o json 2>/dev/null | python3 -c 'import json,sys; print("\n".join(sorted(s["name"] for s in json.load(sys.stdin))))')
  if [ $env = staging ]; then secrets_staging=$names; else secrets_production=$names; fi

  shape=$(supabase db query --linked "select 'extension ' || extname from pg_extension
    union all select 'event trigger ' || evtname || ' ' || evtevent from pg_event_trigger
    union all select 'function ' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
      from pg_proc p where p.pronamespace = 'public'::regnamespace order by 1" -o csv 2>/dev/null | tail -n +2)
  if [ $env = staging ]; then schema_staging=$shape; else schema_production=$shape; fi

  supabase db advisors --linked --level info -o json 2>/dev/null | python3 scripts/ci/advisors.py | sed "s/^/$env: /" || fail "$env has advisor findings the baseline doesn't accept"
done

[ "$secrets_staging" = "$secrets_production" ] \
  || fail "secret names differ: $(diff <(echo "$secrets_staging") <(echo "$secrets_production") | grep '^[<>]' | tr '\n' ' ')"

# Between a merge and the next release tag, objects only on staging are expected (production runs the new
# migrations at the tag). Objects only on production, or a changed signature (both sides), stay an error.
schema_diff=$(diff <(echo "$schema_staging") <(echo "$schema_production") | grep '^[<>]' || true)
if [ "$allow_behind" = --allow-prod-behind ]; then
  staging_only=$(grep '^<' <<<"$schema_diff" || true)
  production_only=$(grep '^>' <<<"$schema_diff" || true)
  [ -z "$staging_only" ] || echo "note: production doesn't have these database objects yet: $(echo "$staging_only" | tr '\n' ' ')"
  [ -z "$production_only" ] \
    || fail "database objects only on production (< staging, > production): $(echo "$schema_diff" | tr '\n' ' ')"
else
  [ -z "$schema_diff" ] || fail "database objects differ (< staging, > production): $(echo "$schema_diff" | tr '\n' ' ')"
fi

[ $status -eq 0 ] && echo "env-parity: staging and production match the repository."
exit $status
