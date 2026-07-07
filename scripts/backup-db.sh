#!/usr/bin/env bash
# scripts/backup-db.sh
#
# pg_dump the running Postgres `db` service into the db_backups volume
# (/backups inside the db container), gzip it, verify it is non-empty, then
# prune dumps older than BACKUP_KEEP days.
#
# Invoked daily by .github/workflows/backup.yml (or run manually / via cron).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

COMPOSE=(docker compose)
KEEP="${BACKUP_KEEP:-14}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="/backups/vision_template-${TS}.sql.gz"

cya() { printf '\033[1;36m==> %s\033[0m\n' "$*"; }

if [[ -z "$("${COMPOSE[@]}" ps -q db)" ]]; then
  echo "!! db service is not running — nothing to back up." >&2
  exit 1
fi

cya "Creating dump: $OUT"
"${COMPOSE[@]}" exec -T -e OUT="$OUT" db \
  sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" | gzip > "$OUT"'

cya "Verifying dump is non-empty"
SIZE="$("${COMPOSE[@]}" exec -T db sh -c "wc -c < \"$OUT\" | tr -d '[:space:]'")"
if [[ -z "$SIZE" || "$SIZE" == "0" ]]; then
  echo "!! Backup is empty — investigate. Removing bogus file." >&2
  "${COMPOSE[@]}" exec -T db sh -c "rm -f \"$OUT\"" || true
  exit 1
fi
printf '   size: %s bytes\n' "$SIZE"

cya "Pruning dumps older than $KEEP day(s)"
"${COMPOSE[@]}" exec -T -e KEEP="$KEEP" db \
  sh -c 'find /backups -type f -name "*.sql.gz" -mtime +"$KEEP" -delete'

cya "Current backups:"
"${COMPOSE[@]}" exec -T db sh -c 'ls -lh /backups'

cya "Done."
