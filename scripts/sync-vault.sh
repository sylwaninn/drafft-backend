#!/usr/bin/env bash
# Writes the database's Vault secrets for one environment, from the same source as the functions:
#   edge_functions_url    https://<ref>.supabase.co/functions/v1
#   db_events_secret      DB_EVENTS_SECRET from supabase/functions/.env.<environment>
#   purchase_environment  the store environment whose purchases count (apply_purchase_event):
#                         SANDBOX on staging, PRODUCTION on production (also the default when unset)
# Creates them or replaces their value. Prints nothing secret.
#
#   scripts/sync-vault.sh staging
#   echo production | scripts/sync-vault.sh production
set -euo pipefail
cd "$(dirname "$0")/.."

PRODUCTION_REF=wrcpgnqwjmnirjfxpcux
STAGING_REF=rjlghcuspdtrmbimyioe

env=${1:-}
case "$env" in
  staging) ref=$STAGING_REF; purchases=SANDBOX ;;
  production)
    ref=$PRODUCTION_REF
    purchases=PRODUCTION
    read -r -p "Write the PRODUCTION Vault ($ref)? Type 'production' to go on: " answer
    [ "$answer" = production ] || { echo "Stopped."; exit 1; }
    ;;
  *) echo "Usage: $0 staging|production" >&2; exit 64 ;;
esac

file="supabase/functions/.env.$env"
# Only this line, without running the file: `KEY=value`, `KEY = value`, quoted or not.
line=$(grep -E '^[[:space:]]*(export[[:space:]]+)?DB_EVENTS_SECRET[[:space:]]*=' "$file" | tail -n 1 || true)
[ -n "$line" ] || { echo "No DB_EVENTS_SECRET line in $file." >&2; exit 1; }
secret=$(printf %s "$line" | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]+$//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/')
[ -n "$secret" ] || { echo "DB_EVENTS_SECRET is empty in $file: set it (openssl rand -hex 32)." >&2; exit 1; }
case "$secret" in *"'"*) echo "DB_EVENTS_SECRET can't contain a quote." >&2; exit 1 ;; esac

upsert() { # name value
  printf "select case when exists (select 1 from vault.secrets where name = '%s')
    then (select vault.update_secret(id, '%s') from vault.secrets where name = '%s')::text
    else vault.create_secret('%s', '%s')::text end;\n" "$1" "$2" "$1" "$2" "$1"
}

sql=$(mktemp)
trap 'rm -f "$sql"' EXIT
{
  upsert edge_functions_url "https://$ref.supabase.co/functions/v1"
  upsert db_events_secret "$secret"
  upsert purchase_environment "$purchases"
} > "$sql"

# On every exit, errors included: remove the SQL file and never leave the CLI linked to production.
cleanup() {
  rm -f "$sql"
  [ "$ref" = "$STAGING_REF" ] && return
  supabase link --project-ref "$STAGING_REF" >/dev/null \
    || echo "warning: couldn't link the CLI back to staging: run supabase link --project-ref $STAGING_REF" >&2
}
trap cleanup EXIT
supabase link --project-ref "$ref" >/dev/null
supabase db query --linked -f "$sql" -o csv >/dev/null
supabase db query --linked "select name, updated_at from vault.secrets order by name" -o table
echo "Vault synced for $env ($ref)."
