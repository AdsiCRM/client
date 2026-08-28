#!/bin/sh
set -e

echo "=== AdsiCRM Setup ==="
echo ""

# 0. Check host dependencies (Docker + Python3) and install whatever's missing —
# so a bare VPS with nothing preinstalled still ends up with a fully working CRM,
# instead of failing halfway through with a confusing "command not found".

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  else
    echo "unknown"
  fi
}
PKG_MANAGER=$(detect_pkg_manager)

install_package() {
  pkg="$1"
  case "$PKG_MANAGER" in
    apt)
      $SUDO apt-get update -qq
      $SUDO apt-get install -y "$pkg"
      ;;
    dnf)
      $SUDO dnf install -y "$pkg"
      ;;
    yum)
      $SUDO yum install -y "$pkg"
      ;;
    *)
      echo "ERROR: Could not detect a supported package manager (apt/dnf/yum) to install '$pkg'."
      echo "Please install '$pkg' manually and re-run this script."
      exit 1
      ;;
  esac
}

fetch_and_run_as_root() {
  url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" | $SUDO sh
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$url" | $SUDO sh
  else
    echo "ERROR: Neither curl nor wget found — cannot download the Docker installer."
    echo "Please install curl or wget, or install Docker manually: https://docs.docker.com/engine/install/"
    exit 1
  fi
}

echo "▸ Checking host dependencies..."

# Docker + the Compose plugin (checked together — "docker compose version" only
# succeeds if both are present and working).
if ! docker compose version >/dev/null 2>&1; then
  echo "  Docker (or the Compose plugin) not found — installing via get.docker.com..."
  fetch_and_run_as_root https://get.docker.com
  $SUDO systemctl enable --now docker >/dev/null 2>&1 || true
  if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: Docker installation failed. Please install it manually: https://docs.docker.com/engine/install/"
    exit 1
  fi
  echo "  Docker installed successfully."
else
  echo "  Docker: OK"
fi

# The daemon itself might be stopped even if the CLI is installed.
if ! docker info >/dev/null 2>&1; then
  echo "  Docker daemon isn't running — starting it..."
  $SUDO systemctl start docker >/dev/null 2>&1 || $SUDO service docker start >/dev/null 2>&1 || true
  if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Could not start the Docker daemon. Please start it manually and re-run this script."
    exit 1
  fi
fi

# Python3 (needed by the planned self-update daemon; harmless to have regardless).
if ! command -v python3 >/dev/null 2>&1; then
  echo "  python3 not found — installing..."
  install_package python3
  if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 installation failed. Please install it manually and re-run this script."
    exit 1
  fi
  echo "  python3 installed successfully."
else
  echo "  python3: OK"
fi

# nginx (host-level, not a container — terminates the real public domain/TLS and
# reverse-proxies to the frontend container; vhost/TLS setup itself is a separate
# step, not done here).
if ! command -v nginx >/dev/null 2>&1; then
  echo "  nginx not found — installing..."
  install_package nginx
  if ! command -v nginx >/dev/null 2>&1; then
    echo "ERROR: nginx installation failed. Please install it manually and re-run this script."
    exit 1
  fi
  $SUDO systemctl enable --now nginx >/dev/null 2>&1 || true
  echo "  nginx installed successfully."
else
  echo "  nginx: OK"
fi

echo ""

# 1. Generate .env from .env.example if not exists
if [ -f ".env" ]; then
  echo "▸ .env already exists, skipping generation."
else
  if [ ! -f ".env.example" ]; then
    echo "ERROR: Neither .env nor .env.example found."
    exit 1
  fi

  echo "▸ Generating .env from .env.example..."

  # DOMAIN/CORS_ORIGIN deliberately NOT asked here — they're handled by the
  # nginx step further down, which runs on EVERY invocation (not just this
  # first-time-only block). That's what lets "no domain yet, bought one
  # later" and "DNS wasn't ready" both resolve the same way: just re-run this
  # script, it asks/retries exactly what's still missing.
  JWT_ACCESS=$(openssl rand -base64 64 | tr -d '\n')
  JWT_REFRESH=$(openssl rand -base64 64 | tr -d '\n')
  DB_PASS=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 24)
  REDIS_PASS=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 24)
  UPDATER_TOKEN=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)

  while IFS= read -r line; do
    case "$line" in
      DB_PASSWORD=CHANGE_ME*)        echo "DB_PASSWORD=$DB_PASS" ;;
      REDIS_PASSWORD=CHANGE_ME*)     echo "REDIS_PASSWORD=$REDIS_PASS" ;;
      JWT_ACCESS_SECRET=CHANGE_ME*)  echo "JWT_ACCESS_SECRET=$JWT_ACCESS" ;;
      JWT_REFRESH_SECRET=CHANGE_ME*) echo "JWT_REFRESH_SECRET=$JWT_REFRESH" ;;
      UPDATER_TOKEN=CHANGE_ME*)      echo "UPDATER_TOKEN=$UPDATER_TOKEN" ;;
      *)                             echo "$line" ;;
    esac
  done < .env.example > .env

  echo "  DB password:    $DB_PASS"
  echo "  Redis password: $REDIS_PASS"
  echo ""
fi

# 2. Start infrastructure
echo "▸ Starting database and cache..."
docker compose up -d db redis

# 3. Wait for PostgreSQL
echo "▸ Waiting for PostgreSQL to be ready..."
MAX_WAIT=60
ELAPSED=0
until docker exec adsicrm-db pg_isready -q 2>/dev/null; do
  if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
    echo ""
    echo "ERROR: PostgreSQL did not become ready within ${MAX_WAIT}s."
    exit 1
  fi
  printf "."
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done
echo " ready!"

# 4. Start backend
echo "▸ Starting backend..."
docker compose up -d backend

# 5. Wait for backend container to fully start
echo "▸ Waiting for backend to start..."
MAX_WAIT=30
ELAPSED=0
until docker exec adsicrm-backend true 2>/dev/null; do
  if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
    echo ""
    echo "ERROR: Backend container did not start within ${MAX_WAIT}s."
    exit 1
  fi
  printf "."
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done
sleep 3
echo " ready!"

# 6. Sync database schema
echo "▸ Syncing database schema..."
docker exec adsicrm-backend prisma db push --accept-data-loss

# 7. Seed database
echo "▸ Seeding database..."
docker exec adsicrm-backend node /app/prisma/seed.cjs

# 8. Start remaining services
echo "▸ Starting frontend and adminer..."
docker compose up -d

# 9. Install the self-update daemon as a systemd service. It has to run on the
# HOST, never in a container — a container's own process tree dies the moment
# `docker compose up -d` recreates it, so nothing living inside backend or
# frontend can safely orchestrate replacing that same container (see
# updater/daemon.py for the full reasoning). systemd keeps it running across
# crashes and reboots without needing a login shell or a container for it.
echo "▸ Installing self-update daemon..."

CLIENT_DIR=$(pwd)
UNIT_PATH="/etc/systemd/system/adsicrm-updater.service"

chmod +x "$CLIENT_DIR/updater/check.sh" "$CLIENT_DIR/updater/update.sh" "$CLIENT_DIR/updater/daemon.py"

if command -v systemctl >/dev/null 2>&1; then
  PYTHON3_BIN=$(command -v python3)
  cat <<EOF | $SUDO tee "$UNIT_PATH" >/dev/null
[Unit]
Description=AdsiCRM self-update daemon
After=network.target docker.service

[Service]
Type=simple
WorkingDirectory=$CLIENT_DIR
EnvironmentFile=$CLIENT_DIR/.env
ExecStart=$PYTHON3_BIN $CLIENT_DIR/updater/daemon.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now adsicrm-updater
  echo "  Updater daemon installed and running (systemd unit: adsicrm-updater)."
else
  echo "  WARNING: systemctl not found — skipping updater daemon install."
  echo "  In-app updates (Settings → System) won't work until it's running."
  echo "  Run manually: UPDATER_TOKEN=... python3 $CLIENT_DIR/updater/daemon.py"
fi

# 10. Domain, then nginx (path-based routing: / -> frontend, /api -> backend)
# and TLS. Runs on EVERY invocation and is fully idempotent — this is
# deliberately the recovery path for both "no domain yet, bought one later"
# and "the domain's DNS wasn't ready during the first run": just re-run this
# script and it asks/retries exactly whatever's still missing, nothing else
# needs to be repeated by hand.

DOMAIN=$(grep -E '^DOMAIN=' .env 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')

if [ -z "$DOMAIN" ]; then
  DOMAIN_REGEX='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
  printf "▸ Do you have a domain pointing at this server? (y/n): "
  read -r HAS_DOMAIN
  case "$HAS_DOMAIN" in
    y|Y|yes|Yes|YES)
      while true; do
        printf "  Enter the domain (e.g. example.com): "
        read -r DOMAIN_INPUT
        # Forgive a pasted protocol/trailing slash/stray whitespace before validating.
        DOMAIN_INPUT=$(echo "$DOMAIN_INPUT" | sed -E 's#^https?://##; s#/+$##' | tr -d '[:space:]')
        if echo "$DOMAIN_INPUT" | grep -Eq "$DOMAIN_REGEX"; then
          DOMAIN="$DOMAIN_INPUT"
          break
        fi
        echo "  Not a valid domain (expected something like example.com) — try again."
      done
      TMP_ENV=$(mktemp)
      awk -v val="DOMAIN=$DOMAIN" '/^DOMAIN=/{print val; next} {print}' .env > "$TMP_ENV" && mv "$TMP_ENV" .env
      TMP_ENV=$(mktemp)
      awk -v val="CORS_ORIGIN=http://$DOMAIN" '/^CORS_ORIGIN=/{print val; next} {print}' .env > "$TMP_ENV" && mv "$TMP_ENV" .env
      echo "  Domain saved — requesting a TLS certificate for it below."
      ;;
    *)
      echo "  No domain — the CRM will be reachable by this server's IP address instead."
      ;;
  esac
fi

# Still no domain (declined above, or on a previous run) — point CORS_ORIGIN at
# the server's real IP instead of leaving it on the .env.example placeholder.
# Only fires while CORS_ORIGIN is still that exact stock value, so this runs
# at most once and never overwrites a manually customized value.
if [ -z "$DOMAIN" ]; then
  CURRENT_CORS=$(grep -E '^CORS_ORIGIN=' .env 2>/dev/null | cut -d= -f2-)
  if [ "$CURRENT_CORS" = "http://localhost:3001" ]; then
    echo "▸ Detecting the server's public IP..."
    PUBLIC_IP=$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
    if [ -n "$PUBLIC_IP" ]; then
      TMP_ENV=$(mktemp)
      awk -v val="CORS_ORIGIN=http://$PUBLIC_IP" '/^CORS_ORIGIN=/{print val; next} {print}' .env > "$TMP_ENV" && mv "$TMP_ENV" .env
    else
      echo "  WARNING: Could not auto-detect the server's IP — leaving CORS_ORIGIN as-is. Fix it in .env manually if needed."
    fi
  fi
fi

echo "▸ Configuring nginx..."

FRONTEND_PORT_VAL=$(grep -E '^FRONTEND_PORT=' .env 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
BACKEND_PORT_VAL=$(grep -E '^BACKEND_PORT=' .env 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
FRONTEND_PORT_VAL=${FRONTEND_PORT_VAL:-3001}
BACKEND_PORT_VAL=${BACKEND_PORT_VAL:-3000}

if [ "$PKG_MANAGER" = "apt" ]; then
  NGINX_CONF_PATH="/etc/nginx/sites-available/adsicrm"
  NGINX_ENABLED_PATH="/etc/nginx/sites-enabled/adsicrm"
  # Debian/Ubuntu's nginx package ships this pre-enabled with its own
  # `listen 80 default_server;` — left in place, it wins over our vhost for
  # any request nginx can't otherwise match, serving the stock "Welcome to
  # nginx!" page instead of the CRM. Safe to remove: only the sites-enabled
  # symlink, the real file stays untouched in sites-available.
  $SUDO rm -f /etc/nginx/sites-enabled/default
else
  NGINX_CONF_PATH="/etc/nginx/conf.d/adsicrm.conf"
  NGINX_ENABLED_PATH=""
fi

# Only ever created once — certbot rewrites this same file in place once a
# certificate is issued (adds the SSL server block + http->https redirect),
# and re-running this script must never clobber that back to plain HTTP.
if [ ! -f "$NGINX_CONF_PATH" ]; then
  cat <<NGINXCONF | $SUDO tee "$NGINX_CONF_PATH" >/dev/null
server {
    listen 80;
    server_name _;

    location /api {
        proxy_pass http://127.0.0.1:${BACKEND_PORT_VAL};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        proxy_pass http://127.0.0.1:${FRONTEND_PORT_VAL};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINXCONF

  if [ -n "$NGINX_ENABLED_PATH" ] && [ ! -e "$NGINX_ENABLED_PATH" ]; then
    $SUDO ln -s "$NGINX_CONF_PATH" "$NGINX_ENABLED_PATH"
  fi

  if $SUDO nginx -t >/dev/null 2>&1; then
    $SUDO systemctl reload nginx >/dev/null 2>&1 || $SUDO service nginx reload >/dev/null 2>&1 || true
    echo "  nginx configured (listening on :80)."
  else
    echo "  WARNING: nginx config test failed — check '$SUDO nginx -t' manually."
  fi
else
  echo "  nginx already configured, skipping."
fi

# TLS — only possible with a real domain (Let's Encrypt won't issue for bare
# IPs). Safe to retry: skips outright if a certificate already exists.
if [ -n "$DOMAIN" ]; then
  if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    echo "  TLS certificate for $DOMAIN already present, skipping certbot."
  else
    echo "▸ Requesting a TLS certificate for $DOMAIN..."
    if ! command -v certbot >/dev/null 2>&1; then
      install_package certbot
      install_package python3-certbot-nginx
    fi
    if command -v certbot >/dev/null 2>&1; then
      if $SUDO certbot --nginx -d "$DOMAIN" --redirect --register-unsafely-without-email --non-interactive --agree-tos >/tmp/adsicrm-certbot.log 2>&1; then
        echo "  TLS certificate obtained — $DOMAIN is now served over HTTPS."
      else
        echo "  WARNING: certbot failed (log: /tmp/adsicrm-certbot.log) — likely the domain's DNS A record isn't pointing at this server yet."
        echo "  Once it is, just re-run this script (sh setup.sh) — it will retry automatically."
      fi
    else
      echo "  WARNING: certbot installation failed — skipping TLS. Re-run this script once it's installed."
    fi
  fi

  # Self-heals CORS_ORIGIN from http to https the moment a certificate exists —
  # covers both "TLS just succeeded above" and "it was already there from a
  # previous run". Only touches the value if it's still exactly our own http
  # default, so a manually-customized CORS_ORIGIN is never overwritten.
  if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    CURRENT_CORS=$(grep -E '^CORS_ORIGIN=' .env 2>/dev/null | cut -d= -f2-)
    if [ "$CURRENT_CORS" = "http://$DOMAIN" ]; then
      TMP_ENV=$(mktemp)
      awk -v val="CORS_ORIGIN=https://$DOMAIN" '/^CORS_ORIGIN=/{print val; next} {print}' .env > "$TMP_ENV" && mv "$TMP_ENV" .env
      echo "  CORS_ORIGIN upgraded to https://$DOMAIN"
    fi
  fi
fi

echo ""
echo "Done! Services are available at:"

ADMINER_PORT=$(grep -E '^ADMINER_PORT=' .env 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
CORS_ORIGIN_VAL=$(grep -E '^CORS_ORIGIN=' .env 2>/dev/null | cut -d= -f2-)

echo "  CRM:      ${CORS_ORIGIN_VAL:-http://localhost:3001}"
echo "  Adminer:  http://localhost:${ADMINER_PORT:-8978} (SSH tunnel only — not linked from the CRM UI)"
echo ""
