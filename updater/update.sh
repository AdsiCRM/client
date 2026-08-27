#!/bin/sh
# Runs check.sh, and if a newer version exists on origin: git pull + docker
# compose pull + docker compose up -d. Meant to be launched detached by
# daemon.py (not called synchronously from the backend) — by the time
# `docker compose up -d` recreates the backend container, whatever asked for
# this update is itself being torn down, so nothing can wait on this script's
# exit code. Progress is instead tracked via STATUS_FILE, polled through
# daemon.py's /status.
set -e

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CLIENT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$CLIENT_DIR"

STATUS_FILE="$SCRIPT_DIR/.status"

set_status() { printf '%s' "$1" > "$STATUS_FILE"; }
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

set_status "updating"
log "Update started."

CHECK_JSON=$(sh "$SCRIPT_DIR/check.sh")
log "Check result: $CHECK_JSON"

case "$CHECK_JSON" in
  *'"updateAvailable":true'*) ;;
  *)
    log "No update available, nothing to do."
    set_status "idle"
    exit 0
    ;;
esac

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)

log "Pulling latest code (branch: $BRANCH)..."
if ! git pull origin "$BRANCH"; then
  log "ERROR: git pull failed."
  set_status "error"
  exit 1
fi

log "Pulling new images..."
if ! docker compose pull; then
  log "ERROR: docker compose pull failed."
  set_status "error"
  exit 1
fi

log "Recreating containers..."
if ! docker compose up -d; then
  log "ERROR: docker compose up failed."
  set_status "error"
  exit 1
fi

log "Update finished successfully."
set_status "idle"
