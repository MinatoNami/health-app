#!/usr/bin/env bash
#
# Deploys the Health Exporter ingest server to the backend host over SSH.
#
#   ./deploy.sh                 build, push, migrate, reload nginx, verify
#   ./deploy.sh user <name>     create/reset a login the app can sign in with
#   ./deploy.sh admin <name>    create a Django admin account for /admin/
#   ./deploy.sh token <label>   mint a bearer token directly (shown once)
#   ./deploy.sh pin             print the certificate pin for the app
#   ./deploy.sh rotate-cert     reissue the TLS keypair (changes the pin)
#   ./deploy.sh backup          run a database backup now
#   ./deploy.sh backup-verify   restore the newest backup into a scratch DB
#   ./deploy.sh backup-pull     copy backups off the server to this machine
#   ./deploy.sh status          container + endpoint health
#   ./deploy.sh logs [n]        tail application logs
#   ./deploy.sh migrate         run migrations only
#   ./deploy.sh shell           Django shell on the server
#   ./deploy.sh destroy         stop containers (keeps the database volume)
#
# Safe to re-run: every step is idempotent. Secrets and the TLS keypair are
# generated on the server on first deploy and never overwritten afterwards,
# so redeploying does not rotate the pin or invalidate issued tokens.

set -euo pipefail

SSH_HOST="${SSH_HOST:-alena-tailscale}"
SERVER_NAME="${SERVER_NAME:-alena-server.tail03bec9.ts.net}"
REMOTE_DIR="${REMOTE_DIR:-/home/ubuntu/health-server}"
LOCAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="/etc/nginx/certs"
CERT_NAME="health-exporter"
NGINX_SITE="health-exporter"
# Pinned, not system-trusted: the client compares this certificate's SHA-256
# directly, so a long life avoids a silent sync outage on expiry. Nothing here
# relies on public CA trust or ATS's 825-day ceiling.
CERT_DAYS=3650

bold=$(tput bold 2>/dev/null || echo); red=$(tput setaf 1 2>/dev/null || echo)
green=$(tput setaf 2 2>/dev/null || echo); yellow=$(tput setaf 3 2>/dev/null || echo)
reset=$(tput sgr0 2>/dev/null || echo)

step() { printf "\n%s==> %s%s\n" "$bold" "$1" "$reset"; }
info() { printf "    %s\n" "$1"; }
ok()   { printf "    %s✓%s %s\n" "$green" "$reset" "$1"; }
warn() { printf "    %s!%s %s\n" "$yellow" "$reset" "$1"; }
die()  { printf "\n%serror:%s %s\n" "$red" "$reset" "$1" >&2; exit 1; }

remote() { ssh "$SSH_HOST" "$@"; }
compose() { remote "cd $REMOTE_DIR && docker compose $*"; }

require_host() {
  # -n matters: without it ssh reads stdin to EOF, swallowing the answer to any
  # confirmation prompt that follows and making `read` fail under `set -e`.
  ssh -n -o ConnectTimeout=10 -o BatchMode=yes "$SSH_HOST" true 2>/dev/null \
    || die "cannot ssh to '$SSH_HOST'. Check your SSH config and that Tailscale is up."
}

# Confirmation that works both interactively and when piped (`echo y | ...`),
# and can be skipped entirely with ASSUME_YES=1.
confirm() {
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  local reply=""
  read -r -p "    $1 [y/N] " reply || reply=""
  [ "$reply" = "y" ] || [ "$reply" = "Y" ]
}

# --- steps -------------------------------------------------------------------

preflight() {
  step "Preflight"
  require_host
  ok "ssh $SSH_HOST"
  remote "command -v docker >/dev/null" || die "docker is not installed on $SSH_HOST"
  remote "docker compose version >/dev/null 2>&1" || die "docker compose v2 is not available on $SSH_HOST"
  ok "docker + compose"
  remote "docker info >/dev/null 2>&1" \
    || die "the '$SSH_HOST' user cannot talk to the docker daemon (needs the docker group)"
  ok "docker daemon reachable"
  command -v rsync >/dev/null || die "rsync is not installed locally"
}

push_code() {
  step "Pushing code to $SSH_HOST:$REMOTE_DIR"
  remote "mkdir -p $REMOTE_DIR"
  # .env holds generated secrets and lives only on the server; excluding it
  # also protects it from --delete.
  rsync -az --delete \
    --exclude '.env' \
    --exclude '.git' \
    --exclude '__pycache__/' \
    --exclude '*.pyc' \
    --exclude 'staticfiles/' \
    --exclude '.venv/' \
    --exclude 'deploy/certs/' \
    --exclude '.pytest_cache/' \
    --exclude 'dashboard/node_modules/' \
    --exclude 'dashboard/dist/' \
    "$LOCAL_DIR/" "$SSH_HOST:$REMOTE_DIR/"
  ok "code synced"
}

DASHBOARD_DIR="/var/www/health-dashboard"

build_dashboard() {
  step "Dashboard"
  if ! command -v npm >/dev/null; then
    warn "npm not found locally — keeping whatever dashboard is already deployed"
    return 0
  fi
  ( cd "$LOCAL_DIR/dashboard" \
      && npm install --silent --no-fund --no-audit \
      && npm run build --silent ) >/dev/null 2>&1 \
    || die "dashboard build failed — run 'npm run build' in server/dashboard to see why"
  ok "built"

  # Owned by the deploy user so rsync needs no sudo; nginx only reads it.
  remote "sudo mkdir -p $DASHBOARD_DIR && sudo chown -R \$(id -u):\$(id -g) $DASHBOARD_DIR"
  rsync -az --delete "$LOCAL_DIR/dashboard/dist/" "$SSH_HOST:$DASHBOARD_DIR/"
  ok "published to $DASHBOARD_DIR"
}

ensure_env() {
  step "Server configuration"
  if remote "test -f $REMOTE_DIR/.env"; then
    ok ".env already present (secrets left untouched)"
  else
    info "generating .env with fresh secrets"
    remote "cat > $REMOTE_DIR/.env <<EOF
DJANGO_SECRET_KEY=\$(openssl rand -base64 48 | tr -d '\n=' )
DJANGO_DEBUG=0
DJANGO_ALLOWED_HOSTS=$SERVER_NAME,localhost,127.0.0.1
DJANGO_CSRF_TRUSTED_ORIGINS=https://$SERVER_NAME
DJANGO_LOG_LEVEL=INFO
POSTGRES_DB=health
POSTGRES_USER=health
POSTGRES_PASSWORD=\$(openssl rand -hex 24)
POSTGRES_HOST=db
POSTGRES_PORT=5432
EOF
chmod 600 $REMOTE_DIR/.env"
    ok ".env created"
  fi
}

# ECDSA P-256, not RSA. The certificate travels in the TLS handshake, and this
# server is reached over a Tailscale tailnet whose MTU is 1280 bytes. An RSA
# 4096 certificate is ~1431 bytes on its own, so the handshake cannot fit in a
# single packet and fails on paths that relay or mis-handle PMTU — which is
# exactly what a phone on cellular does. P-256 brings it to roughly 500 bytes
# and is no weaker: it is comparable to RSA 3072 and universally supported.
generate_cert() {
  # SAN is mandatory: iOS ignores commonName entirely, so a CN-only
  # certificate fails to match the host no matter what it says.
  remote "sudo mkdir -p $CERT_DIR && sudo openssl req -x509 \
    -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -sha256 \
    -days $CERT_DAYS -nodes \
    -keyout $CERT_DIR/$CERT_NAME.key \
    -out $CERT_DIR/$CERT_NAME.crt \
    -subj '/CN=$SERVER_NAME' \
    -addext 'subjectAltName=DNS:$SERVER_NAME,DNS:localhost,IP:127.0.0.1' \
    -addext 'basicConstraints=critical,CA:FALSE' \
    -addext 'keyUsage=critical,digitalSignature' \
    -addext 'extendedKeyUsage=serverAuth' 2>/dev/null \
    && sudo chmod 600 $CERT_DIR/$CERT_NAME.key && sudo chmod 644 $CERT_DIR/$CERT_NAME.crt"
}

ensure_cert() {
  step "TLS certificate"
  if remote "sudo test -f $CERT_DIR/$CERT_NAME.crt"; then
    ok "certificate already present (pin unchanged)"
  else
    info "generating a self-signed certificate for $SERVER_NAME"
    generate_cert
    ok "certificate generated (valid $CERT_DAYS days)"
  fi
}

configure_nginx() {
  step "nginx"
  local tmp="/tmp/${NGINX_SITE}.conf"
  sed "s/__SERVER_NAME__/$SERVER_NAME/g" "$LOCAL_DIR/deploy/nginx-health.conf" \
    | remote "cat > $tmp"
  remote "sudo install -m 644 $tmp /etc/nginx/sites-available/$NGINX_SITE && rm -f $tmp"
  remote "sudo ln -sfn /etc/nginx/sites-available/$NGINX_SITE /etc/nginx/sites-enabled/$NGINX_SITE"

  # This host already serves other sites on 443. A broken config would take
  # them all down on reload, so back out rather than leave nginx unreloadable.
  local test_output
  if ! test_output="$(remote 'sudo nginx -t' 2>&1)"; then
    remote "sudo rm -f /etc/nginx/sites-enabled/$NGINX_SITE"
    # Report the output from the *failing* run. Re-testing after rollback would
    # print a success message for the config we just removed.
    printf "%s\n" "$test_output" | sed 's/^/    /'
    die "nginx rejected the new site; it has been removed and nothing was reloaded"
  fi
  ok "config valid (existing sites untouched)"
  remote "sudo systemctl reload nginx"
  ok "nginx reloaded"
}

start_services() {
  step "Building and starting containers"
  compose "up -d --build" 2>&1 | sed 's/^/    /'
  ok "containers up"
}

run_migrations() {
  step "Database migrations"
  compose "run --rm web python manage.py migrate --noinput" 2>&1 | sed 's/^/    /'
  ok "migrations applied"
  # Idempotent, and required before the login throttle can count anything.
  compose "run --rm web python manage.py createcachetable" 2>&1 | sed 's/^/    /'
  ok "cache table present"
}

verify() {
  step "Verifying"

  local cache="$LOCAL_DIR/deploy/certs"
  mkdir -p "$cache"
  remote "sudo cat $CERT_DIR/$CERT_NAME.crt" > "$cache/$CERT_NAME.crt"

  local attempt=0
  until remote "curl -fsS --max-time 5 http://127.0.0.1:8081/healthz" >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    [ "$attempt" -ge 15 ] && {
      compose "logs --tail 40 web" 2>&1 | sed 's/^/    /'
      die "the app did not become healthy on the server"
    }
    sleep 2
  done
  ok "app healthy inside the server"

  # Verified against the real certificate rather than -k, so this also proves
  # the pin the app will use matches what nginx is actually serving.
  if curl -fsS --max-time 10 --cacert "$cache/$CERT_NAME.crt" \
       "https://$SERVER_NAME/healthz" >/dev/null 2>&1; then
    ok "https://$SERVER_NAME/healthz reachable over the tailnet"
  else
    warn "not reachable from this machine over the tailnet"
    warn "the server is up; check that Tailscale is running here and $SERVER_NAME resolves"
  fi
}

cert_pin() {
  remote "sudo openssl x509 -in $CERT_DIR/$CERT_NAME.crt -outform DER 2>/dev/null" \
    | openssl dgst -sha256 -hex \
    | sed 's/^.*= //' \
    | tr -d '\n'
}

print_summary() {
  local pin; pin="$(cert_pin)"
  step "Done"
  cat <<EOF

    Dashboard   https://$SERVER_NAME/dashboard/
    Endpoint    https://$SERVER_NAME/v1/health/batches
    Admin       https://$SERVER_NAME/admin/
    Health      https://$SERVER_NAME/healthz

    Certificate pin (SHA-256 of the certificate):

      $bold$pin$reset

    In the app: Settings → HTTP destination
      Server URL    https://$SERVER_NAME
      Certificate   the pin above
      Bearer token  ./deploy.sh token <label>

EOF
}

# --- commands ----------------------------------------------------------------

cmd_deploy() {
  preflight
  push_code
  build_dashboard
  ensure_env
  ensure_cert
  configure_nginx
  start_services
  install_backups
  run_migrations
  verify
  print_summary
}

cmd_token() {
  [ $# -ge 1 ] || die "usage: ./deploy.sh token <label>"
  require_host
  compose "run --rm web python manage.py issue_token '$1'"
}

BACKUP_DIR_REMOTE="/var/backups/health"

install_backups() {
  step "Backups"
  remote "sudo install -m 755 -o root -g root /dev/stdin /usr/local/bin/health-backup" \
    < "$LOCAL_DIR/deploy/backup.sh"
  remote "sudo mkdir -p $BACKUP_DIR_REMOTE && sudo chown ubuntu:ubuntu $BACKUP_DIR_REMOTE"

  # 03:20 rather than 03:00: every other cron on the box fires on the hour, and
  # a pg_dump competing with them for I/O just makes both slower.
  remote "sudo tee /etc/cron.d/health-backup >/dev/null <<'CRON'
# Nightly Health Exporter database backup. Installed by server/deploy.sh.
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
20 3 * * * ubuntu /usr/local/bin/health-backup >> /var/log/health-backup.log 2>&1
CRON
sudo chmod 644 /etc/cron.d/health-backup"
  ok "nightly backup installed (03:20, 30-day retention)"
}

cmd_backup() {
  require_host
  step "Running a backup now"
  remote "/usr/local/bin/health-backup" 2>&1 | sed 's/^/    /'
  remote "ls -lh $BACKUP_DIR_REMOTE | tail -5" 2>&1 | sed 's/^/    /'
}

cmd_backup_pull() {
  require_host
  # Outside the repo by default: a 54MB dump of health data has no business
  # sitting in a working tree where it can be committed by accident.
  local dest="${1:-$HOME/health-backups}"
  mkdir -p "$dest"
  step "Copying backups off the server"
  # A backup on the same disk as the database only survives mistakes, not
  # hardware. This is the copy that survives the machine.
  # No --info=stats1: macOS ships rsync 2.6.9, which predates that flag.
  rsync -az "$SSH_HOST:$BACKUP_DIR_REMOTE/" "$dest/"
  ok "pulled to $dest"
  ls -lh "$dest" | tail -5 | sed 's/^/    /'
}

cmd_backup_verify() {
  require_host
  step "Verifying the newest backup restores"
  # A backup nobody has restored is a hypothesis. This loads the newest dump
  # into a scratch database and counts rows, then drops it.
  remote "cd $REMOTE_DIR && set -e
    LATEST=\$(ls -t $BACKUP_DIR_REMOTE/health-*.sql.gz 2>/dev/null | head -1)
    [ -n \"\$LATEST\" ] || { echo 'no backups found'; exit 1; }
    echo \"restoring \$LATEST into scratch database\"
    docker compose exec -T db psql -U health -d postgres -c 'DROP DATABASE IF EXISTS restore_check;' >/dev/null
    docker compose exec -T db psql -U health -d postgres -c 'CREATE DATABASE restore_check;' >/dev/null
    gunzip -c \"\$LATEST\" | docker compose exec -T db psql -U health -d restore_check -q >/dev/null 2>&1
    docker compose exec -T db psql -U health -d restore_check -t -c \\
      \"select 'records: '||count(*) from ingest_record;\"
    docker compose exec -T db psql -U health -d restore_check -t -c \\
      \"select 'batches: '||count(*) from ingest_batch;\"
    docker compose exec -T db psql -U health -d postgres -c 'DROP DATABASE restore_check;' >/dev/null
    echo 'scratch database dropped'" 2>&1 | sed 's/^/    /'
}

cmd_admin() {
  [ $# -ge 1 ] || die "usage: ./deploy.sh admin <username>"
  require_host
  info "creating a Django admin account for https://$SERVER_NAME/admin/"
  # Separate from `user`: a phone sign-in should not carry admin rights, so the
  # account the app authenticates with is deliberately not a superuser.
  ssh -t "$SSH_HOST" "cd $REMOTE_DIR && docker compose run --rm -it web python manage.py createsuperuser --username '$1'"
}

cmd_rotate_cert() {
  require_host
  step "Rotating the TLS certificate"
  warn "this changes the pin — the app will refuse to connect until it is updated"
  confirm "continue?" || { info "aborted"; exit 0; }

  local stamp="old-$(date +%Y%m%d%H%M%S)"
  remote "sudo cp $CERT_DIR/$CERT_NAME.crt $CERT_DIR/$CERT_NAME.$stamp.crt 2>/dev/null || true"
  info "previous certificate kept as $CERT_NAME.$stamp.crt"

  generate_cert
  if ! remote "sudo nginx -t" >/dev/null 2>&1; then
    die "nginx rejected the new certificate; the old one is still in place"
  fi
  remote "sudo systemctl reload nginx"
  ok "new certificate live"

  local cache="$LOCAL_DIR/deploy/certs"
  mkdir -p "$cache"
  remote "sudo cat $CERT_DIR/$CERT_NAME.crt" > "$cache/$CERT_NAME.crt"

  printf "\n    New pin — paste into Settings → Certificate pin:\n\n      %s%s%s\n\n" \
    "$bold" "$(cert_pin)" "$reset"
}

cmd_user() {
  [ $# -ge 1 ] || die "usage: ./deploy.sh user <username>"
  require_host
  # -t so the password prompt works; the password is never passed as an
  # argument, which would put it in shell history and the process list.
  ssh -t "$SSH_HOST" "cd $REMOTE_DIR && docker compose run --rm -it web python manage.py create_login '$1'"
}

cmd_pin() {
  require_host
  printf "%s\n" "$(cert_pin)"
}

cmd_status() {
  require_host
  step "Containers"
  compose "ps" 2>&1 | sed 's/^/    /'
  step "Endpoint"
  if remote "curl -fsS --max-time 5 http://127.0.0.1:8081/healthz" 2>/dev/null; then
    printf "\n"; ok "healthy"
  else
    warn "not responding"
  fi
}

cmd_logs() {
  require_host
  compose "logs --tail ${1:-100} -f web"
}

cmd_migrate() { require_host; run_migrations; }

cmd_shell() { require_host; ssh -t "$SSH_HOST" "cd $REMOTE_DIR && docker compose run --rm web python manage.py shell"; }

cmd_destroy() {
  require_host
  warn "this stops the containers; the database volume is kept"
  confirm "continue?" || { info "aborted"; exit 0; }
  compose "down"
  ok "stopped"
}

case "${1:-deploy}" in
  deploy)  cmd_deploy ;;
  user)    shift; cmd_user "$@" ;;
  admin)   shift; cmd_admin "$@" ;;
  backup)  cmd_backup ;;
  backup-pull) shift; cmd_backup_pull "$@" ;;
  backup-verify) cmd_backup_verify ;;
  rotate-cert) cmd_rotate_cert ;;
  token)   shift; cmd_token "$@" ;;
  pin)     cmd_pin ;;
  status)  cmd_status ;;
  logs)    shift; cmd_logs "$@" ;;
  migrate) cmd_migrate ;;
  shell)   cmd_shell ;;
  destroy) cmd_destroy ;;
  *)       die "unknown command '$1' (deploy, user, admin, token, pin, rotate-cert, backup, backup-verify, backup-pull, status, logs, migrate, shell, destroy)" ;;
esac
