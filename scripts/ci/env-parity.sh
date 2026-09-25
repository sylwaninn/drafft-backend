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

repo_migrations=$(ls supabase/migrations | sed -E 's/_.*//' | sort)
repo_functions=$(find supabase/functions -mindepth 2 -maxdepth 2 -name index.ts | awk -F/ '{print $3}' | sort)

secrets_staging=""
secrets_production=""
schema_staging=""
schema_production=""
for env in staging production; do
  ref=$STAGING_REF; [ $env = production ] && ref=$PRODUCTION_REF
  supabase link --project-ref "$ref" >/dev/null 2>&1

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
supabase link --project-ref "$STAGING_REF" >/dev/null 2>&1

[ "$secrets_staging" = "$secrets_production" ] \
  || fail "secret names differ: $(diff <(echo "$secrets_staging") <(echo "$secrets_production") | grep '^[<>]' | tr '\n' ' ')"

[ "$schema_staging" = "$schema_production" ] \
  || fail "database objects differ (< staging, > production): $(diff <(echo "$schema_staging") <(echo "$schema_production") | grep '^[<>]' | tr '\n' ' ')"

[ $status -eq 0 ] && echo "env-parity: staging and production match the repository."
exit $status
