#!/usr/bin/env bash
# Offline copy of the Supabase database: a nightly logical dump pulled to this machine over
# kubectl exec, so Postgres never has to listen on the network.
#   <stamp>.dump       pg_dump -Fc of the database (restores into any same-or-newer Postgres)
#   <stamp>.roles.sql  pg_dumpall --roles-only — Supabase's roles (anon, authenticated, seanpe_api, …)
#                      must exist before the dump will restore cleanly
set -euo pipefail

CONTEXT=${CONTEXT:-seanpe-homelab}
NAMESPACE=${NAMESPACE:-supabase}
SELECTOR=${SELECTOR:-app.kubernetes.io/name=supabase-db}
CONTAINER=${CONTAINER:-supabase-db}
DATABASE=${DATABASE:-postgres}
DB_USER=${DB_USER:-supabase_admin}
DEST=${DEST:-$HOME/backups/supabase}
KEEP=${KEEP:-14}

k() { kubectl --context "$CONTEXT" -n "$NAMESPACE" "$@"; }

mkdir -p "$DEST"
pod=$(k get pod -l "$SELECTOR" -o jsonpath='{.items[0].metadata.name}')
stamp="$DEST/supabase-$(date +%F-%H%M)"

# PGPASSWORD is already set in the container from the chart's db secret.
k exec "$pod" -c "$CONTAINER" -- pg_dump -h localhost -U "$DB_USER" -Fc -d "$DATABASE" > "$stamp.dump.partial"
k exec "$pod" -c "$CONTAINER" -- pg_dumpall -h localhost -U "$DB_USER" --roles-only > "$stamp.roles.sql.partial"
# Validate with the server's own pg_restore — a truncated or unreadable archive is not a backup.
k exec -i "$pod" -c "$CONTAINER" -- pg_restore --list < "$stamp.dump.partial" > /dev/null
mv "$stamp.dump.partial" "$stamp.dump"
mv "$stamp.roles.sql.partial" "$stamp.roles.sql"

ls -1t "$DEST"/supabase-*.dump | tail -n +"$((KEEP + 1))" | while read -r old; do
  rm -- "$old" "${old%.dump}.roles.sql"
done
echo "wrote $stamp.dump ($(du -h "$stamp.dump" | cut -f1)), keeping $KEEP"
