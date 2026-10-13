#!/usr/bin/env bash
#
# `restic`, configured for the off-host backup repository. Installed on the
# server as /usr/local/bin/health-restic by `deploy.sh`; the nightly backup, the
# deploy commands and a person restoring by hand all go through it, so there is
# one place that knows where the repository is and how to open it.
#
#   health-restic snapshots
#   health-restic dump latest health.sql | less
#   health-restic check --read-data-subset=5%
#
# Configuration lives in .env, set by `./deploy.sh offsite <repository>`:
#
#   RESTIC_REPOSITORY  sftp:user@host:/path — a machine on the tailnet
#   RESTIC_PASSWORD    the repository key; without it the backups are noise
#
# The password goes to restic down a file descriptor rather than through the
# environment or argv, the same rule backup.sh follows for the gpg passphrase.

set -euo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-/home/ubuntu/health-server}"
ENV_FILE="$COMPOSE_DIR/.env"
# A key used for nothing else, so authorising it on the backup machine grants
# exactly this and can be revoked without touching anything else.
SSH_KEY="${HEALTH_BACKUP_SSH_KEY:-$HOME/.ssh/health-backup}"

read_env() { sed -n "s/^$1=//p" "$ENV_FILE" 2>/dev/null | head -1; }

REPO="$(read_env RESTIC_REPOSITORY)"
PASSWORD="$(read_env RESTIC_PASSWORD)"

[ -n "$REPO" ] || { echo "health-restic: RESTIC_REPOSITORY is not set (./deploy.sh offsite <repository>)" >&2; exit 3; }
[ -n "$PASSWORD" ] || { echo "health-restic: RESTIC_PASSWORD is not set" >&2; exit 3; }

args=(--repo "$REPO" --password-file /dev/fd/3)

case "$REPO" in
  sftp:*)
    # sftp:user@host:/path. restic's default ssh would use whatever key and
    # host-key policy the account happens to have; spelling the command out
    # pins the dedicated key and makes a missing authorisation fail fast
    # (BatchMode) instead of hanging on a prompt nobody will answer at 03:20.
    spec="${REPO#sftp:}"
    target="${spec%%:*}"
    args+=(-o "sftp.command=ssh -i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new $target -s sftp")
    ;;
esac

exec restic "${args[@]}" "$@" 3<<<"$PASSWORD"
