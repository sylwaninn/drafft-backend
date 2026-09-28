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
prod_behind=""
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
deployed_staging=""
advisors_staging=$(mktemp)
# The baseline production's code shipped with (last v* tag); none: every finding stays an error.
released_baseline=$(mktemp)
trap 'rm -f "$advisors_staging" "$released_baseline"; relink_staging' EXIT
tag=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
{ [ -n "$tag" ] && git show "$tag:supabase/advisors-baseline.json" 2>/dev/null; } > "$released_baseline" || echo "{}" > "$released_baseline"
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
      prod_behind=1
    else
      fail "$env hasn't run: $(echo $missing)"
    fi
  fi

  deployed=$(supabase functions list --project-ref "$ref" -o json 2>/dev/null | python3 -c 'import json,sys; print("\n".join(sorted(f["slug"] for f in json.load(sys.stdin))))')
  if [ $env = staging ]; then deployed_staging=$deployed; fi
  functions_diff=$(diff <(echo "$repo_functions") <(echo "$deployed") | grep '^[<>]' || true)
  if [ $env = production ] && [ "$allow_behind" = --allow-prod-behind ] && [ -n "$functions_diff" ]; then
    # Behind, production may lack a function of the repository that staging already deploys (a note).
    # One on production only, or one staging doesn't deploy either, stays an error.
    not_yet=$(grep '^<' <<<"$functions_diff" | cut -c3- | comm -12 - <(echo "$deployed_staging") || true)
    unexpected=$(grep -vxF -f <(sed 's/^/< /' <<<"$not_yet") <<<"$functions_diff" || true)
    [ -z "$not_yet" ] || echo "note: production doesn't deploy these functions yet: $(echo $not_yet)"
    [ -z "$unexpected" ] || fail "production functions differ from the repository: $(echo "$unexpected" | tr '\n' ' ')"
  else
    [ -z "$functions_diff" ] || fail "$env functions differ from the repository: $(echo "$functions_diff" | tr '\n' ' ')"
  fi

  names=$(supabase secrets list --project-ref "$ref" -o json 2>/dev/null | python3 -c 'import json,sys; print("\n".join(sorted(s["name"] for s in json.load(sys.stdin))))')
  if [ $env = staging ]; then secrets_staging=$names; else secrets_production=$names; fi

  shape=$(supabase db query --linked "select 'extension ' || extname from pg_extension
    union all select 'event trigger ' || evtname || ' ' || evtevent from pg_event_trigger
    union all select 'function ' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
      from pg_proc p where p.pronamespace = 'public'::regnamespace order by 1" -o csv 2>/dev/null | tail -n +2)
  if [ $env = staging ]; then schema_staging=$shape; else schema_production=$shape; fi

  # Behind, production may still have findings that a migration fixed on staging and removed from the
  # baseline: a note while staging no longer has them and the released baseline accepted them. One on both,
  # or new on production, stays an error.
  fixed_in=()
  if [ $env = production ] && [ "$allow_behind" = --allow-prod-behind ]; then fixed_in=(--fixed-in "$advisors_staging" --released-baseline "$released_baseline"); fi
  advisors_json=$(supabase db advisors --linked --level info -o json 2>/dev/null)
  [ $env = staging ] && echo "$advisors_json" > "$advisors_staging"
  echo "$advisors_json" | python3 scripts/ci/advisors.py ${fixed_in[@]+"${fixed_in[@]}"} | sed "s/^/$env: /" || fail "$env has advisor findings the baseline doesn't accept"
done

[ "$secrets_staging" = "$secrets_production" ] \
  || fail "secret names differ: $(diff <(echo "$secrets_staging") <(echo "$secrets_production") | grep '^[<>]' | tr '\n' ' ')"

# The name of a database object without its signature: "function ack_event(p_id bigint)" -> "function ack_event".
# The CSV output quotes a line with a comma (several arguments): the quote goes too.
object_name() { sed -E 's/^"//; s/\(.*$//'; }

# Between a merge and the next release tag, objects only on staging are expected (production runs the new
# migrations at the tag). An object only on production is a note only while production lags migrations and
# staging has an object of the same type and name with another signature (a signature replaced by a migration
# production hasn't run yet). Any other object only on production stays an error.
schema_diff=$(diff <(echo "$schema_staging") <(echo "$schema_production") | grep '^[<>]' || true)
if [ "$allow_behind" = --allow-prod-behind ]; then
  staging_only=$(grep '^<' <<<"$schema_diff" | cut -c3- || true)
  production_only=$(grep '^>' <<<"$schema_diff" | cut -c3- || true)
  replaced=""
  if [ -n "$prod_behind" ] && [ -n "$production_only" ]; then
    staging_names=$(object_name <<<"$schema_staging" | sort -u)
    replaced=$(while IFS= read -r object; do
      grep -qxF "$(object_name <<<"$object")" <<<"$staging_names" && printf '%s\n' "$object"
    done <<<"$production_only" || true)
  fi
  orphans=$(grep -vxF -f <(printf '%s\n' "$replaced" | sed '/^$/d') <<<"$production_only" || true)
  [ -n "$replaced" ] || orphans=$production_only
  [ -z "$staging_only" ] || echo "note: production doesn't have these database objects yet: $(echo "$staging_only" | tr '\n' ' ')"
  [ -z "$replaced" ] || echo "note: production still has these signatures, replaced on staging: $(echo "$replaced" | tr '\n' ' ')"
  [ -z "$orphans" ] \
    || fail "database objects only on production: $(echo "$orphans" | tr '\n' ' ')"
else
  [ -z "$schema_diff" ] || fail "database objects differ (< staging, > production): $(echo "$schema_diff" | tr '\n' ' ')"
fi

[ $status -eq 0 ] && echo "env-parity: staging and production match the repository."
exit $status
