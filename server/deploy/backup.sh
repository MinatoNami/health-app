#!/usr/bin/env bash
#
# Nightly Postgres backup. Installed on the server by `deploy.sh` and run from
# cron; also runnable by hand via `./deploy.sh backup`.
#
# Two years of health data exist in exactly one place — a Docker volume. A disk
# failure or a mistaken `docker compose down -v` loses all of it, and unlike the
# phone's outbox there is no second copy to re-send from.

set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/var/backups/health}"
COMPOSE_DIR="${COMPOSE_DIR:-/home/ubuntu/health-server}"
KEEP_DAYS="${KEEP_DAYS:-30}"
STAMP="$(date +%Y%m%d-%H%M%S)"
TARGET="$BACKUP_DIR/health-$STAMP.sql.gz"

mkdir -p "$BACKUP_DIR"
cd "$COMPOSE_DIR"

# --clean --if-exists so the dump can be restored over an existing database
# without hand-dropping it first; -T so cron has no tty to fight over.
docker compose exec -T db pg_dump \
    --username="${POSTGRES_USER:-health}" \
    --dbname="${POSTGRES_DB:-health}" \
    --clean --if-exists \
  | gzip -9 > "$TARGET.partial"

# Only becomes a real backup once the dump has completed. An interrupted run
# leaving a truncated .sql.gz that *looks* like a backup is the classic way to
# discover you have none.
mv "$TARGET.partial" "$TARGET"

# Cheap integrity check: gzip verifies its own CRC, so a truncated or corrupt
# archive fails here rather than at restore time months later.
if ! gzip -t "$TARGET"; then
    echo "backup failed integrity check, removing: $TARGET" >&2
    rm -f "$TARGET"
    exit 1
fi

SIZE="$(du -h "$TARGET" | cut -f1)"
echo "$(date -Is) backup ok: $TARGET ($SIZE)"

# Retention. Deliberately after the new backup succeeds, so a failing run never
# prunes the last good copy.
find "$BACKUP_DIR" -name 'health-*.sql.gz' -type f -mtime "+$KEEP_DAYS" -print -delete
find "$BACKUP_DIR" -name '*.partial' -type f -mtime +1 -delete
