#!/usr/bin/env bash
# Ships the backend to one environment: migrations, then Edge Functions, then (with --secrets) the
# functions' secrets from supabase/functions/.env.<environment>, then the areas (scripts/load-areas.ts).
#
#   scripts/deploy.sh staging [--secrets]
#   scripts/deploy.sh production [--secrets]
#   echo production | scripts/deploy.sh production   (no terminal to type the confirmation in)
#
# Staging first, always. The CLI is linked back to staging on the way out, success or failure, so a
# stray `supabase db push` never lands on production.
set -euo pipefail
cd "$(dirname "$0")/.."

PRODUCTION_REF=wrcpgnqwjmnirjfxpcux
# The persistent branch `staging` of drafft-backend (`supabase branches get staging`).
STAGING_REF=rjlghcuspdtrmbimyioe

env=${1:-}
case "$env" in
  staging) ref=$STAGING_REF ;;
  production)
    ref=$PRODUCTION_REF
    read -r -p "Deploy to PRODUCTION ($ref)? Type 'production' to go on: " answer
    [ "$answer" = production ] || { echo "Stopped."; exit 1; }
    ;;
  *) echo "Usage: $0 staging|production [--secrets]" >&2; exit 64 ;;
esac
# A project ref is 20 lowercase letters: anything else is a placeholder or a typo.
[[ "$ref" =~ ^[a-z]{20}$ ]] || { echo "Set a valid project ref for $env in $0 first (got '$ref')." >&2; exit 1; }

# Runs on every exit, errors included: never leave the CLI linked to production.
relink_staging() {
  [ "$ref" = "$STAGING_REF" ] && return
  supabase link --project-ref "$STAGING_REF" >/dev/null \
    || echo "warning: couldn't link the CLI back to staging: run supabase link --project-ref $STAGING_REF" >&2
}
trap relink_staging EXIT

supabase link --project-ref "$ref"
supabase db push
# Bundled by Supabase (--use-api), not in a local Docker: the same everywhere, CI runners included, where
# the Docker bundler fails ("No such file or directory").
supabase functions deploy --project-ref "$ref" --use-api

if [ "${2:-}" = --secrets ]; then
  # Read by the CLI only, never printed.
  supabase secrets set --project-ref "$ref" --env-file "supabase/functions/.env.$env"
fi

# The areas area_at answers from (private.areas): loaded when they differ from the source, a no-op otherwise.
deno run -A scripts/load-areas.ts "$env" --yes

echo "Deployed to $env ($ref)."
