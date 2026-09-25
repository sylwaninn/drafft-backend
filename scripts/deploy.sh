#!/usr/bin/env bash
# Ships the backend to one environment: migrations, then Edge Functions, then (with --secrets) the
# functions' secrets from supabase/functions/.env.<environment>.
#
#   scripts/deploy.sh staging [--secrets]
#   scripts/deploy.sh production [--secrets]
#   echo production | scripts/deploy.sh production   (no terminal to type the confirmation in)
#
# Staging first, always. The CLI stays linked to staging afterwards, so a stray `supabase db push`
# never lands on production.
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
[ "$ref" != STAGING_REF ] || { echo "Set STAGING_REF in $0 first." >&2; exit 1; }

supabase link --project-ref "$ref"
supabase db push
supabase functions deploy --project-ref "$ref"

if [ "${2:-}" = --secrets ]; then
  # Read by the CLI only, never printed.
  supabase secrets set --project-ref "$ref" --env-file "supabase/functions/.env.$env"
fi

[ "$ref" = "$STAGING_REF" ] || supabase link --project-ref "$STAGING_REF"
echo "Deployed to $env ($ref)."
