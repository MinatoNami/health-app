#!/bin/bash
# Renews the Tailscale-issued certificate nginx serves. Installed to
# /usr/local/bin/renew-health-cert by server/deploy.sh and run weekly.
#
# Tailscale certificates last 90 days, and `tailscale cert` is a no-op until
# roughly the last 14 — so a weekly run does nothing most weeks and has eight
# chances to succeed before one lapses.
#
# The reload is the half that matters. nginx serves the certificate it opened at
# startup, so a renewed file sitting on disk unserved is invisible until the old
# one expires, at which point the app stops connecting and it looks like a
# network fault months after the change that caused it.
set -euo pipefail

CERT_DIR="${CERT_DIR:-/etc/nginx/certs}"
CERT_NAME="${CERT_NAME:-health-exporter}"
SERVER_NAME="${SERVER_NAME:-alena-server.tail03bec9.ts.net}"

crt="$CERT_DIR/$CERT_NAME.crt"
key="$CERT_DIR/$CERT_NAME.key"

before=$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null || echo none)
tailscale cert --cert-file "$crt" --key-file "$key" "$SERVER_NAME" >/dev/null
chmod 600 "$key"
chmod 644 "$crt"
after=$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null || echo none)

# Only reload when the certificate actually moved. A weekly reload that changes
# nothing is noise in the log that hides the week it mattered.
if [ "$before" != "$after" ]; then
    nginx -t >/dev/null && systemctl reload nginx
    echo "$(date -Is) renewed: $before -> $after"
else
    echo "$(date -Is) unchanged ($after)"
fi
