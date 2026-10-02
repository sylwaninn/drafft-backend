#!/usr/bin/env bash
# Creates supabase/functions/.env.local (gitignored), the local Edge Functions' environment, ONCE: never
# when it already exists. From then on it's yours: edit it by hand, nothing here writes it again.
# The first version is .env.staging (Stream, R2, APNs, Rekognition, Resend, Twilio) with local values:
#   DB_EVENTS_SECRET         the local Vault's, from seed.sql
#   REVENUECAT_WEBHOOK_AUTH  random; RevenueCat's extra webhook to the tunnel sends it
#   SEND_EMAIL_HOOK_SECRET   the local Auth hooks', from config.toml
#   SEND_SMS_HOOK_SECRET
#   MAILPIT_URL              auth emails and SMS go to the local Mailpit...
#   EMAIL_REAL, SMS_REAL     ...unless set to true: then Resend and Twilio really send (costs money)
# Prints nothing secret.
#
#   scripts/local-env.sh                           # then: supabase functions serve --env-file supabase/functions/.env.local
#   scripts/local-env.sh --webhook-auth | pbcopy   # the Authorization value for RevenueCat, to the clipboard
set -euo pipefail
cd "$(dirname "$0")/.."

source_file=supabase/functions/.env.staging
out=supabase/functions/.env.local
keys='DB_EVENTS_SECRET|REVENUECAT_WEBHOOK_AUTH|SEND_EMAIL_HOOK_SECRET|SEND_SMS_HOOK_SECRET|MAILPIT_URL|AUTH_PUBLIC_URL|SMS_REAL|EMAIL_REAL'
line_of() { grep -E "^[[:space:]]*(export[[:space:]]+)?$1[[:space:]]*=" "$2" 2>/dev/null | tail -n 1 || true; }
value_of() { line_of "$1" "$2" | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]+$//; s/^"(.*)"$/\1/'; }

case "${1:-}" in
  "") ;;
  --webhook-auth)
    auth=$(value_of REVENUECAT_WEBHOOK_AUTH "$out")
    [ -n "$auth" ] || { echo "No REVENUECAT_WEBHOOK_AUTH in $out." >&2; exit 1; }
    printf %s "$auth"
    exit 0
    ;;
  *) echo "Usage: $0 [--webhook-auth]" >&2; exit 64 ;;
esac

if [ -e "$out" ]; then
  echo "$out already exists: left as it is (edit it by hand)." >&2
  exit 1
fi

[ -f "$source_file" ] || { echo "No $source_file (see docs/environments.md, Staging setup)." >&2; exit 1; }
# The statement itself, not the example in seed.sql's header comment.
db_events=$(grep -oE "^select vault\.create_secret\('[^']+', 'db_events_secret'\)" supabase/seed.sql \
  | tail -n 1 | sed -E "s/^[^']*'([^']+)'.*/\1/")
[ -n "$db_events" ] || { echo "No db_events_secret in supabase/seed.sql." >&2; exit 1; }
# The `secrets` line of one [auth.hook.<name>] section.
hook_secret() { awk -v s="[auth.hook.$1]" '$0 == s { on = 1; next } /^\[/ { on = 0 } on && /^secrets = / { gsub(/^secrets = "|"$/, ""); print }' supabase/config.toml; }
email_hook=$(hook_secret send_email)
sms_hook=$(hook_secret send_sms)
[ -n "$email_hook" ] && [ -n "$sms_hook" ] || { echo "No send_email/send_sms hook secret in supabase/config.toml." >&2; exit 1; }

umask 077
# noclobber: fails rather than overwrite, even if the file appeared since the check above.
set -o noclobber
{
  echo "# Local Edge Functions. First written by scripts/local-env.sh from $(basename "$source_file"); yours since."
  # Drops the local keys; every other line, multi-line values included, is copied as is.
  grep -vE "^[[:space:]]*(export[[:space:]]+)?($keys)[[:space:]]*=" "$source_file"
  echo "DB_EVENTS_SECRET=$db_events"
  echo "REVENUECAT_WEBHOOK_AUTH=$(openssl rand -hex 32)"
  echo "SEND_EMAIL_HOOK_SECRET=$email_hook"
  echo "SEND_SMS_HOOK_SECRET=$sms_hook"
  echo "MAILPIT_URL=http://host.docker.internal:55424"
  echo "EMAIL_REAL=false"
  echo "SMS_REAL=false"
  # Mailpit takes any sender: staging's if it has one, a placeholder otherwise.
  [ -n "$(line_of EMAIL_FROM "$source_file")" ] || echo "EMAIL_FROM=drafft <no-reply@mail.getdrafft.com>"
} > "$out"
echo "Wrote $out. It's yours now: this script won't write it again."
echo "Run: supabase functions serve --env-file $out"
