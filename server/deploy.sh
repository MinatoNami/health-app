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
#   ./deploy.sh llm [url]       point the server at your LM Studio and verify it
#   ./deploy.sh llm off         disable insight generation
#   ./deploy.sh alerts <url>    where to push when a signal stops arriving
#   ./deploy.sh alerts test     send a test alert now
#   ./deploy.sh alerts check    report stale metrics without sending
#   ./deploy.sh purge           permanently delete all health data
#   ./deploy.sh backup          run a database backup now
#   ./deploy.sh backup-key      show (or generate) the backup passphrase
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
CERT_CRON="/etc/cron.d/health-cert"

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
LLM_ENABLED=1
INSIGHT_RETENTION_DAYS=30
EOF
chmod 600 $REMOTE_DIR/.env"
    ok ".env created"
  fi

  # Deliberately not written into the generated .env: the right value depends on
  # which machine is running LM Studio and whether it is published on the
  # tailnet, and a wrong default here would look configured while failing.
  if ! remote "grep -q '^LLM_BASE_URL=' $REMOTE_DIR/.env"; then
    info "no model server configured yet — run ./deploy.sh llm to point at LM Studio"
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

# Tailscale issues a real certificate for this name, so nothing here is
# self-signed any more and the app pins nothing.
#
# It was until 2026-08-17. `tailscale cert` returned "your Tailscale account
# does not support getting TLS certs" for this tailnet, and the iOS app requires
# https://, so the server ran a self-signed certificate whose SHA-256 the app
# carried. Enabling Tailscale Serve turned HTTPS Certificates on tailnet-wide
# and the workaround stopped being necessary. `generate_cert` stays for a host
# that cannot get one — a different tailnet, or the setting turned back off —
# and is the fallback rather than the default.
ensure_cert() {
  step "TLS certificate"
  if remote "sudo test -f $CERT_DIR/$CERT_NAME.crt"; then
    ok "certificate already present"
    return
  fi
  info "requesting a certificate for $SERVER_NAME from Tailscale"
  if remote "sudo tailscale cert --cert-file $CERT_DIR/$CERT_NAME.crt --key-file $CERT_DIR/$CERT_NAME.key $SERVER_NAME >/dev/null 2>&1"; then
    remote "sudo chmod 600 $CERT_DIR/$CERT_NAME.key && sudo chmod 644 $CERT_DIR/$CERT_NAME.crt"
    ok "certificate issued by Let's Encrypt via Tailscale"
  else
    warn "Tailscale would not issue a certificate for $SERVER_NAME."
    warn "Falling back to self-signed; the app needs the pin from './deploy.sh pin'."
    generate_cert
    ok "self-signed certificate generated (valid $CERT_DAYS days)"
  fi
}

install_cert_renewal() {
  step "Certificate renewal"
  if ! remote "sudo openssl x509 -in $CERT_DIR/$CERT_NAME.crt -noout -issuer 2>/dev/null | grep -qi \"let's encrypt\""; then
    info "self-signed certificate — nothing to renew"
    return
  fi
  remote "sudo install -m 755 -o root -g root /dev/stdin /usr/local/bin/renew-health-cert" \
    < "$LOCAL_DIR/deploy/renew-cert.sh"
  # Sunday 04:17, away from the 03:20 backup so two things are not competing for
  # the disk. A no-op most weeks; see deploy/renew-cert.sh for why it exists.
  remote "sudo tee $CERT_CRON >/dev/null <<'CRON'
# Weekly Tailscale certificate renewal. Installed by server/deploy.sh.
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
17 4 * * 0 root /usr/local/bin/renew-health-cert >> /var/log/health-cert.log 2>&1
CRON"
  ok "weekly renewal installed (Sundays 04:17)"
  info "→ /var/log/health-cert.log"
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
  # Only a self-signed certificate needs a pin, and that is now the fallback
  # rather than the normal case. Printing 64 hex characters under every deploy
  # of a publicly trusted server invites pasting them into an app that would
  # then reject a perfectly valid certificate.
  local cert_note=""
  if ! remote "sudo openssl x509 -in $CERT_DIR/$CERT_NAME.crt -noout -issuer 2>/dev/null | grep -qi \"let's encrypt\""; then
    cert_note=" — self-signed here, so paste: $(cert_pin)"
  fi
  step "Done"
  cat <<EOF

    Dashboard   https://$SERVER_NAME/dashboard/
    Endpoint    https://$SERVER_NAME/v1/health/batches
    Admin       https://$SERVER_NAME/admin/
    Health      https://$SERVER_NAME/healthz

    In the app: Settings → HTTP destination
      Server URL    https://$SERVER_NAME
      Certificate   leave empty$cert_note
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
  install_cert_renewal
  install_freshness_cron
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

ensure_backup_key() {
  # Generated as part of the deploy so backups are never silently plaintext,
  # but not printed here — `./deploy.sh backup-key` shows it deliberately.
  if ! remote "grep -q '^BACKUP_PASSPHRASE=.\\+' $REMOTE_DIR/.env"; then
    set_env_var "BACKUP_PASSPHRASE" "$(openssl rand -base64 36 | tr -d '\n=+/' )"
    warn "generated a backup passphrase — run ./deploy.sh backup-key and save it"
    warn "somewhere off this machine, or the encrypted backups are unopenable if"
    warn "the server is lost."
  fi
}

install_backups() {
  ensure_backup_key
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
  # One line a night is slow growth, but nothing was ever going to truncate it.
  remote "sudo tee /etc/logrotate.d/health-backup >/dev/null <<'ROTATE'
/var/log/health-backup.log {
    monthly
    rotate 6
    compress
    missingok
    notifempty
    create 0644 ubuntu ubuntu
}
ROTATE
sudo chmod 644 /etc/logrotate.d/health-backup"
  ok "nightly backup installed (03:20, 30-day retention, rotated log)"
}

cmd_backup() {
  require_host
  step "Running a backup now"
  remote "/usr/local/bin/health-backup" 2>&1 | sed 's/^/    /'
  remote "ls -lh $BACKUP_DIR_REMOTE | tail -5" 2>&1 | sed 's/^/    /'
}

# The passphrase protecting the dumps.
#
# Generated on the server and never rotated automatically: rotating it would
# silently strand every existing backup, since gpg symmetric encryption has no
# key hierarchy to re-wrap. Losing it means losing every backup, so the deploy
# prints it once and says so.
cmd_backup_key() {
  require_host

  if [ "${1:-}" = "--generate" ] || ! remote "grep -q '^BACKUP_PASSPHRASE=.\\+' $REMOTE_DIR/.env"; then
    if remote "grep -q '^BACKUP_PASSPHRASE=.\\+' $REMOTE_DIR/.env"; then
      warn "a passphrase already exists. Replacing it makes every existing"
      warn "backup permanently unreadable — there is no re-wrap for symmetric gpg."
      confirm "replace it anyway?" || { info "aborted"; exit 0; }
    fi
    set_env_var "BACKUP_PASSPHRASE" "$(openssl rand -base64 36 | tr -d '\n=+/' )"
    ok "generated"
  fi

  local pass
  pass=$(remote "sed -n 's/^BACKUP_PASSPHRASE=//p' $REMOTE_DIR/.env | head -1")
  cat <<EOF

    Backup passphrase:

      ${bold}${pass}${reset}

    ${yellow}Store this in a password manager now.${reset} It lives in .env on the
    server it protects, so if that machine dies you have the encrypted
    backups and no way to open them — which is the same as having none.

    To restore by hand:
      gpg --decrypt health-YYYYmmdd-HHMMSS.sql.gz.gpg | gunzip | psql ...

EOF
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
  remote "cd $REMOTE_DIR && set -e -o pipefail
    LATEST=\$(ls -t $BACKUP_DIR_REMOTE/health-*.sql.gz.gpg $BACKUP_DIR_REMOTE/health-*.sql.gz 2>/dev/null | head -1)
    [ -n \"\$LATEST\" ] || { echo 'no backups found'; exit 1; }
    echo \"restoring \$LATEST into scratch database\"
    PASS=\$(sed -n 's/^BACKUP_PASSPHRASE=//p' .env 2>/dev/null | head -1)
    # Encrypted dumps go through gpg first. This is the step that proves the
    # passphrase in .env still opens the files — the thing you least want to
    # find out during an actual restore.
    case \"\$LATEST\" in
      *.gpg) [ -n \"\$PASS\" ] || { echo 'backup is encrypted but BACKUP_PASSPHRASE is not set'; exit 1; }
             READ_CMD=\"gpg --batch --quiet --decrypt --pinentry-mode loopback --passphrase-fd 3 \$LATEST 3<<<\\\$PASS | gunzip -c\" ;;
      *)     READ_CMD=\"gunzip -c \$LATEST\" ;;
    esac
    docker compose exec -T db psql -U health -d postgres -c 'DROP DATABASE IF EXISTS restore_check;' >/dev/null
    docker compose exec -T db psql -U health -d postgres -c 'CREATE DATABASE restore_check;' >/dev/null
    eval \"\$READ_CMD\" | docker compose exec -T db psql -U health -d restore_check -q >/dev/null 2>&1
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

# --- LLM routing -------------------------------------------------------------
#
# The model runs on a laptop; the server runs on the tailnet host. Two things
# have to be true for the container to reach it, and both fail silently:
#
# 1. LM Studio binds 127.0.0.1 by default, so nothing off that machine can see
#    it. `tailscale serve --bg --http=1234 http://127.0.0.1:1234` publishes it on
#    the tailnet interface *only* — better than LM Studio's "serve on local
#    network" toggle, which binds every interface including whatever wifi the
#    laptop is on.
# 2. `tailscale serve` routes by Host header, so the MagicDNS name is required.
#    A bare tailnet IP connects fine and then returns 404, which reads like a
#    broken API rather than a routing mistake.
#
# The link itself is WireGuard-encrypted by Tailscale, which is why plain HTTP
# is acceptable here and not on the phone's upload path: that one crosses
# networks Tailscale does not control, and LM Studio cannot terminate TLS.

llm_default_url() {
  # The laptop this script is being run from, if it is on the tailnet.
  local name
  name="$(tailscale status --json 2>/dev/null \
    | sed -n 's/.*"DNSName": *"\([^"]*\)\.".*/\1/p' | head -1)"
  [ -n "$name" ] && printf "http://%s:1234/v1" "$name"
}

set_env_var() {
  # Replaces the key if present, appends it otherwise. Idempotent, and leaves
  # every other secret in .env untouched.
  local key="$1" value="$2"
  remote "cd $REMOTE_DIR && touch .env && \
    (grep -q '^${key}=' .env && sed -i 's|^${key}=.*|${key}=${value}|' .env \
      || echo '${key}=${value}' >> .env) && chmod 600 .env"
}

cmd_llm() {
  require_host

  if [ "${1:-}" = "off" ]; then
    set_env_var "LLM_ENABLED" "0"
    compose "up -d web" >/dev/null 2>&1
    ok "insight generation disabled; the deterministic analysis endpoints are unaffected"
    return 0
  fi

  local url="${1:-}"
  if [ -z "$url" ]; then
    url="$(llm_default_url)"
    [ -n "$url" ] || die "could not work out this machine's tailnet name; pass the URL explicitly:
    ./deploy.sh llm http://<your-machine>.<tailnet>.ts.net:1234/v1"
    info "using this machine's tailnet name: $url"
  fi

  case "$url" in
    http://127.0.0.1*|http://localhost*)
      warn "127.0.0.1 inside the container is the container itself, not your laptop."
      warn "Use the MagicDNS name of the machine running LM Studio."
      ;;
    http://100.*|https://100.*)
      warn "That is a bare tailnet IP. 'tailscale serve' routes by Host header and"
      warn "will answer 404 — use the MagicDNS name instead."
      ;;
  esac

  step "Checking the model server is reachable from the container"
  set_env_var "LLM_BASE_URL" "$url"
  set_env_var "LLM_ENABLED" "1"
  compose "up -d web" >/dev/null 2>&1
  sleep 2

  # `manage.py shell -c`, not `python -c`: the latter never calls django.setup(),
  # so reading a setting raises ImproperlyConfigured and this probe reported
  # "not reachable" for a model server that was answering perfectly well.
  local probe
  probe=$(remote "cd $REMOTE_DIR && docker compose exec -T web python manage.py shell -c \"
from ingest.llm import client
import json
print(json.dumps(client.status()))
\" 2>/dev/null" || true)

  if printf '%s' "$probe" | grep -q '\"reachable\": true'; then
    ok "reachable at $url"
    printf '%s' "$probe" | sed -n 's/.*\"model\": \"\([^\"]*\)\".*/    model: \1/p'
  else
    warn "not reachable from the container yet."
    printf '%s\n' "$probe" | sed 's/^/    /' | head -4
    cat <<EOF

    On the machine running LM Studio:
      tailscale serve --bg --http=1234 http://127.0.0.1:1234
      tailscale serve status          # confirm it is published

    Insights degrade to the measured snapshot until this works, so nothing
    is broken in the meantime.
EOF
  fi
}

# --- Alerting ----------------------------------------------------------------

cmd_alerts() {
  require_host

  case "${1:-show}" in
    check)
      compose "exec -T web python manage.py check_freshness --dry-run"
      return 0
      ;;
    test)
      step "Sending a test alert"
      # --force ignores the renotify window, which otherwise makes a second
      # test look like a broken webhook.
      compose "exec -T web python manage.py check_freshness --force"
      return 0
      ;;
    show)
      remote "grep -E '^ALERT_' $REMOTE_DIR/.env" 2>/dev/null \
        || info "no alert webhook configured — nothing is pushed when a signal stops"
      return 0
      ;;
    off)
      set_env_var "ALERT_WEBHOOK_URL" ""
      compose "up -d web" >/dev/null 2>&1
      ok "alerting disabled"
      return 0
      ;;
  esac

  local url="$1" format="${2:-text}"
  case "$url" in
    http://*|https://*) ;;
    *) die "expected a URL, got '$url'
    ./deploy.sh alerts https://ntfy.example.com/health-sync
    ./deploy.sh alerts https://hooks.slack.com/... json" ;;
  esac

  set_env_var "ALERT_WEBHOOK_URL" "$url"
  set_env_var "ALERT_WEBHOOK_FORMAT" "$format"
  compose "up -d web" >/dev/null 2>&1
  ok "alerts will POST to $url ($format)"

  warn "metric names and dates leave this machine when an alert fires"
  warn "(\"Sleep duration: last recorded 2026-06-27\") — no measurements, but"
  warn "still health-adjacent. A self-hosted or tailnet-only endpoint is better."

  step "Sending a test alert"
  compose "exec -T web python manage.py check_freshness --force"
}

FRESHNESS_CRON="/etc/cron.d/health-freshness"

install_freshness_cron() {
  step "Freshness check"
  # 09:00 local: a morning report about last night's sync is actionable before
  # the day starts. 03:20 would be correct for a backup and useless for this.
  remote "sudo install -m 644 -o root -g root /dev/stdin $FRESHNESS_CRON <<'CRON'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
0 9 * * * ubuntu cd $REMOTE_DIR && docker compose exec -T web python manage.py check_freshness >> /var/log/health-freshness.log 2>&1
# Monday morning. --skip-if-unreachable because the model lives on a laptop and
# a shut laptop is the normal case, not a fault worth mailing about.
30 8 * * 1 ubuntu cd $REMOTE_DIR && docker compose exec -T web python manage.py weekly_review --skip-if-unreachable >> /var/log/health-freshness.log 2>&1
CRON"
  ok "freshness daily at 09:00, weekly review Mondays at 08:30"
  info "→ /var/log/health-freshness.log"
}

# --- Deletion ----------------------------------------------------------------

cmd_purge() {
  require_host
  step "Permanent deletion"
  warn "this deletes every health record, batch, goal and stored question."
  warn "backups in /var/backups/health are NOT touched — delete those separately"
  warn "if you mean it, or a restore will bring all of it back."
  confirm "permanently delete all health data?" || { info "aborted"; exit 0; }
  ssh -t "$SSH_HOST" "cd $REMOTE_DIR && docker compose exec -T web python manage.py purge_health_data --confirm"
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
  backup-key) shift; cmd_backup_key "$@" ;;
  backup-verify) cmd_backup_verify ;;
  rotate-cert) cmd_rotate_cert ;;
  token)   shift; cmd_token "$@" ;;
  pin)     cmd_pin ;;
  llm)     shift; cmd_llm "$@" ;;
  alerts)  shift; cmd_alerts "$@" ;;
  purge)   cmd_purge ;;
  status)  cmd_status ;;
  logs)    shift; cmd_logs "$@" ;;
  migrate) cmd_migrate ;;
  shell)   cmd_shell ;;
  destroy) cmd_destroy ;;
  *)       die "unknown command '$1' (deploy, user, admin, token, pin, llm, rotate-cert, backup, backup-verify, backup-pull, status, logs, migrate, shell, destroy)" ;;
esac
