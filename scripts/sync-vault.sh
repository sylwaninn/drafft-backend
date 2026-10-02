#!/usr/bin/env bash
# Writes staging's Vault secrets, from the same source as the functions:
#   edge_functions_url    https://<ref>.supabase.co/functions/v1
#   db_events_secret      DB_EVENTS_SECRET from supabase/functions/.env.<environment>
#   purchase_environment  the store environment whose purchases count (apply_purchase_event):
#                         SANDBOX on staging (PRODUCTION is the default when unset, as on production)
#   media_base_url        MEDIA_PUBLIC_URL, where the media Worker serves signed links (when set)
#   media_signing_key     MEDIA_SIGNING_KEY, the key those links are signed with (when set)
# Creates them or replaces their value. Prints nothing secret.
#
#   scripts/sync-vault.sh staging
#
# Never production: its Vault is changed from the dashboard's SQL editor (docs/environments.md), so no
# script run from a laptop can write to it.
set -euo pipefail
cd "$(dirname "$0")/.."

STAGING_REF=rjlghcuspdtrmbimyioe

env=${1:-}
case "$env" in
  staging) ref=$STAGING_REF; purchases=SANDBOX ;;
  *) echo "Usage: $0 staging (never production)" >&2; exit 64 ;;
esac

file="supabase/functions/.env.$env"
# Only this line, without running the file: `KEY=value`, `KEY = value`, quoted or not.
line=$(grep -E '^[[:space:]]*(export[[:space:]]+)?DB_EVENTS_SECRET[[:space:]]*=' "$file" | tail -n 1 || true)
[ -n "$line" ] || { echo "No DB_EVENTS_SECRET line in $file." >&2; exit 1; }
secret=$(printf %s "$line" | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]+$//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/')
[ -n "$secret" ] || { echo "DB_EVENTS_SECRET is empty in $file: set it (openssl rand -hex 32)." >&2; exit 1; }
case "$secret" in *"'"*) echo "DB_EVENTS_SECRET can't contain a quote." >&2; exit 1 ;; esac

# Another variable of the same file, same rules; empty when absent.
value_of() {
  grep -E "^[[:space:]]*(export[[:space:]]+)?$1[[:space:]]*=" "$file" | tail -n 1 \
    | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]+$//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/' || true
}
media_url=$(value_of MEDIA_PUBLIC_URL)
media_key=$(value_of MEDIA_SIGNING_KEY)
case "$media_url$media_key" in *"'"*) echo "MEDIA_PUBLIC_URL and MEDIA_SIGNING_KEY can't contain a quote." >&2; exit 1 ;; esac
[ -n "$media_key" ] || echo "No MEDIA_SIGNING_KEY in $file: media links stay unsigned (public bucket only)." >&2

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
  [ -z "$media_url" ] || upsert media_base_url "$media_url"
  [ -z "$media_key" ] || upsert media_signing_key "$media_key"
} > "$sql"

supabase link --project-ref "$ref" >/dev/null
supabase db query --linked -f "$sql" -o csv >/dev/null
supabase db query --linked "select name, updated_at from vault.secrets order by name" -o table
echo "Vault synced for $env ($ref)."
