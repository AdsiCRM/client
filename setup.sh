#!/bin/sh
set -e

echo "=== AdsiCRM Setup ==="
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

  JWT_ACCESS=$(openssl rand -base64 64 | tr -d '\n')
  JWT_REFRESH=$(openssl rand -base64 64 | tr -d '\n')
  DB_PASS=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 24)
  REDIS_PASS=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 24)

  while IFS= read -r line; do
    case "$line" in
      DB_PASSWORD=CHANGE_ME*)        echo "DB_PASSWORD=$DB_PASS" ;;
      REDIS_PASSWORD=CHANGE_ME*)     echo "REDIS_PASSWORD=$REDIS_PASS" ;;
      JWT_ACCESS_SECRET=CHANGE_ME*)  echo "JWT_ACCESS_SECRET=$JWT_ACCESS" ;;
      JWT_REFRESH_SECRET=CHANGE_ME*) echo "JWT_REFRESH_SECRET=$JWT_REFRESH" ;;
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

echo ""
echo "Done! Services are available at:"

FRONTEND_PORT=$(grep -E '^FRONTEND_PORT=' .env 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
BACKEND_PORT=$(grep -E '^BACKEND_PORT=' .env 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
ADMINER_PORT=$(grep -E '^ADMINER_PORT=' .env 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')

echo "  Frontend:  http://localhost:${FRONTEND_PORT:-3001}"
echo "  Backend:   http://localhost:${BACKEND_PORT:-3000}/swagger"
echo "  Adminer:   http://localhost:${ADMINER_PORT:-8978}"
echo ""
