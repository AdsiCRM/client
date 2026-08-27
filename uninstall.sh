#!/bin/sh
# Fully removes an AdsiCRM install set up by setup.sh: containers, volumes
# (all data), the self-update daemon's systemd service, the nginx site config
# (and its TLS certificate, if any), and finally this whole checkout directory.
#
# No prompts, no flags — meant to be run once, deliberately, by whoever has
# SSH access to the box, when they want a truly clean slate (e.g. to redo the
# install with a domain that wasn't set up the first time around).
set -e

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"

echo "=== AdsiCRM Uninstall ==="
echo ""

# 1. Containers + named volumes (db_data, redis_data, backend_storage) — full
# data wipe, so a subsequent setup.sh run starts from nothing.
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  echo "▸ Removing containers and volumes..."
  docker compose down -v --remove-orphans 2>/dev/null || true
else
  echo "▸ Docker not found, skipping container/volume removal."
fi

# 2. Self-update daemon (systemd).
echo "▸ Removing the self-update daemon..."
if command -v systemctl >/dev/null 2>&1; then
  $SUDO systemctl stop adsicrm-updater >/dev/null 2>&1 || true
  $SUDO systemctl disable adsicrm-updater >/dev/null 2>&1 || true
  $SUDO rm -f /etc/systemd/system/adsicrm-updater.service
  $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
fi

# 3. nginx site config (+ TLS certificate, if setup.sh obtained one).
echo "▸ Removing nginx configuration..."
DOMAIN=""
if [ -f "$SCRIPT_DIR/.env" ]; then
  DOMAIN=$(grep -E '^DOMAIN=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')
fi

NGINX_PATHS="/etc/nginx/sites-available/adsicrm /etc/nginx/sites-enabled/adsicrm /etc/nginx/conf.d/adsicrm.conf"
for path in $NGINX_PATHS; do
  [ -e "$path" ] && $SUDO rm -f "$path"
done

if command -v nginx >/dev/null 2>&1; then
  if $SUDO nginx -t >/dev/null 2>&1; then
    $SUDO systemctl reload nginx >/dev/null 2>&1 || $SUDO service nginx reload >/dev/null 2>&1 || true
  fi
fi

if [ -n "$DOMAIN" ] && command -v certbot >/dev/null 2>&1; then
  $SUDO certbot delete --cert-name "$DOMAIN" --non-interactive >/dev/null 2>&1 || true
fi

# 4. This checkout itself — deliberately last, and deliberately deferred a
# moment via a detached background job, since a script deleting the very
# directory it's currently executing from is only safe once its own file has
# finished being read by the shell.
echo "▸ Removing CRM files..."
CLIENT_DIR="$SCRIPT_DIR"
cd /
nohup sh -c "sleep 1; rm -rf \"$CLIENT_DIR\"" >/dev/null 2>&1 &

echo ""
echo "Done. CRM fully removed (files will finish deleting in the background)."
