#!/usr/bin/env bash
#
# Nightly Postgres backup. Installed on the server by `deploy.sh` and run from
# cron; also runnable by hand via `./deploy.sh backup`.
#
# Two years of health data exist in exactly one place — a Docker volume. A disk
# failure or a mistaken `docker compose down -v` loses all of it, and unlike the
# phone's outbox there is no second copy to re-send from.
#
# The dump is encrypted with gpg (AES-256, symmetric). What that does and does
# not protect is worth being precise about, because the passphrase lives in
# .env on this same machine:
#
#   * Protected: copies pulled to a laptop by `./deploy.sh backup-pull`, backup
#     media, and anyone who ends up with the files but not the .env — which is
#     most of the realistic ways a database dump escapes.
#   * Not protected: someone who already has root here. They can read .env.
#
# That is still worth doing. The dump is a complete, portable copy of years of
# health data; it should not be sitting in /var/backups as plaintext, and it
# certainly should not travel to a laptop that way.

set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/var/backups/health}"
COMPOSE_DIR="${COMPOSE_DIR:-/home/ubuntu/health-server}"
KEEP_DAYS="${KEEP_DAYS:-30}"
STAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
cd "$COMPOSE_DIR"

# .env is mode 600. Read the passphrase from it rather than the environment so
# the value never appears in the process list or in cron's mail.
PASSPHRASE="$(sed -n 's/^BACKUP_PASSPHRASE=//p' "$COMPOSE_DIR/.env" 2>/dev/null | head -1 || true)"

if [ -n "$PASSPHRASE" ]; then
    TARGET="$BACKUP_DIR/health-$STAMP.sql.gz.gpg"
    ENCRYPTED=1
else
    # An unencrypted backup beats no backup, so this warns rather than aborts —
    # but it warns every single night until it is fixed.
    echo "$(date -Is) WARNING: BACKUP_PASSPHRASE is not set; writing an UNENCRYPTED dump." >&2
    echo "  Fix with: ./deploy.sh backup-key --generate" >&2
    TARGET="$BACKUP_DIR/health-$STAMP.sql.gz"
    ENCRYPTED=0
fi

dump() {
    # --clean --if-exists so the dump can be restored over an existing database
    # without hand-dropping it first; -T so cron has no tty to fight over.
    docker compose exec -T db pg_dump \
        --username="${POSTGRES_USER:-health}" \
        --dbname="${POSTGRES_DB:-health}" \
        --clean --if-exists \
      | gzip -9
}

if [ "$ENCRYPTED" = 1 ]; then
    # --passphrase-fd 3 with a here-string: the secret goes down a file
    # descriptor, never onto disk and never into argv.
    dump | gpg --batch --yes --quiet --symmetric \
               --cipher-algo AES256 --compress-algo none \
               --pinentry-mode loopback --passphrase-fd 3 \
               --output "$TARGET.partial" 3<<<"$PASSPHRASE"
else
    dump > "$TARGET.partial"
fi

# Only becomes a real backup once the whole pipeline has completed. An
# interrupted run leaving a truncated file that *looks* like a backup is the
# classic way to discover you have none.
#
# pipefail matters here: without it a failing pg_dump still exits 0 because gzip
# succeeded on the empty stream, and the "backup" is a valid archive of nothing.
mv "$TARGET.partial" "$TARGET"

# Integrity check. For an encrypted dump this also proves the passphrase in .env
# actually decrypts what was just written — the failure you least want to
# discover during a restore.
if [ "$ENCRYPTED" = 1 ]; then
    if ! gpg --batch --quiet --decrypt --pinentry-mode loopback \
             --passphrase-fd 3 "$TARGET" 3<<<"$PASSPHRASE" | gzip -t; then
        echo "backup failed integrity check, removing: $TARGET" >&2
        rm -f "$TARGET"
        exit 1
    fi
else
    if ! gzip -t "$TARGET"; then
        echo "backup failed integrity check, removing: $TARGET" >&2
        rm -f "$TARGET"
        exit 1
    fi
fi

SIZE="$(du -h "$TARGET" | cut -f1)"
echo "$(date -Is) backup ok: $TARGET ($SIZE)$([ "$ENCRYPTED" = 1 ] && echo ' [encrypted]')"

# Retention. Deliberately after the new backup succeeds, so a failing run never
# prunes the last good copy. Both patterns are pruned so plaintext dumps written
# before encryption was turned on still age out.
find "$BACKUP_DIR" -name 'health-*.sql.gz' -type f -mtime "+$KEEP_DAYS" -print -delete
find "$BACKUP_DIR" -name 'health-*.sql.gz.gpg' -type f -mtime "+$KEEP_DAYS" -print -delete
find "$BACKUP_DIR" -name '*.partial' -type f -mtime +1 -delete

# --- Off-host copy -------------------------------------------------------------
#
# Everything above still leaves the only copies on this machine, next to the
# volume they back up: a dead disk or a lost host takes both. When a restic
# repository is configured, the dump just written — and just verified — goes to
# it as well.
#
# The *uncompressed* SQL goes in, not the .gpg file. restic encrypts on its own
# and deduplicates by content, and consecutive dumps of a database that mostly
# grows are mostly the same bytes — so a night costs roughly what changed. A gpg
# file is different bytes every night and would cost its full size each time.
#
# A failure here never touches the local backup above, which has already
# succeeded. It is reported loudly instead: to the log, to the alert webhook if
# one is configured, and through the exit status.

RESTIC_REPOSITORY="$(sed -n 's/^RESTIC_REPOSITORY=//p' "$COMPOSE_DIR/.env" 2>/dev/null | head -1 || true)"
[ -n "$RESTIC_REPOSITORY" ] || exit 0

alert() {
    local url format
    url="$(sed -n 's/^ALERT_WEBHOOK_URL=//p' "$COMPOSE_DIR/.env" 2>/dev/null | head -1 || true)"
    format="$(sed -n 's/^ALERT_WEBHOOK_FORMAT=//p' "$COMPOSE_DIR/.env" 2>/dev/null | head -1 || true)"
    [ -n "$url" ] || return 0
    if [ "$format" = "json" ]; then
        curl -fsS --max-time 15 -H 'Content-Type: application/json' \
             -d "{\"text\": \"$1\"}" "$url" >/dev/null || true
    else
        curl -fsS --max-time 15 -d "$1" "$url" >/dev/null || true
    fi
}

offsite_failed() {
    echo "$(date -Is) OFFSITE FAILED: $1" >&2
    alert "Health backup: the off-host copy failed ($1). The local backup is fine; the off-host one is now a night behind."
    exit 2
}

read_dump() {
    if [ "$ENCRYPTED" = 1 ]; then
        gpg --batch --quiet --decrypt --pinentry-mode loopback \
            --passphrase-fd 3 "$TARGET" 3<<<"$PASSPHRASE" | gunzip -c
    else
        gunzip -c "$TARGET"
    fi
}

read_dump | health-restic backup --quiet --stdin --stdin-filename health.sql \
                --tag nightly --host health-server \
    || offsite_failed "restic backup exited non-zero"
echo "$(date -Is) offsite ok: $RESTIC_REPOSITORY"

# Weekly, on Sundays: thin the snapshots, then read back a slice of the data.
# `check` without --read-data only proves the index is consistent; reading a
# rotating tenth of the pack files catches bit rot on the far side in about
# ten weeks without downloading the whole repository every time.
if [ "$(date +%u)" = 7 ]; then
    health-restic forget --quiet --host health-server --tag nightly \
        --keep-daily 14 --keep-weekly 8 --keep-monthly 24 --prune \
        || offsite_failed "restic forget/prune exited non-zero"
    health-restic check --quiet --read-data-subset="$(( 10#$(date +%V) % 10 + 1 ))/10" \
        || offsite_failed "restic check found a problem in the repository"
    echo "$(date -Is) offsite pruned and checked"
fi
