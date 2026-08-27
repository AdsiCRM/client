#!/bin/sh
# Pure version check — no side effects beyond `git fetch` (updates the local
# remote-tracking ref only, never touches the working tree or app.json).
# Prints one line of JSON to stdout. Called directly by daemon.py, and by
# update.sh before it does anything real.
set -e

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CLIENT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$CLIENT_DIR"

extract_version() {
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

CURRENT_VERSION=$(extract_version < app.json)
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)

FETCH_LOG=$(mktemp)
if ! git fetch origin "$BRANCH" --quiet 2>"$FETCH_LOG"; then
  ERR=$(tr '\n' ' ' < "$FETCH_LOG" | sed 's/"/\\"/g')
  rm -f "$FETCH_LOG"
  printf '{"currentVersion":"%s","latestVersion":null,"updateAvailable":false,"error":"git fetch failed: %s"}\n' "$CURRENT_VERSION" "$ERR"
  exit 0
fi
rm -f "$FETCH_LOG"

REMOTE_VERSION=$(git show "origin/$BRANCH:app.json" 2>/dev/null | extract_version)

if [ -z "$REMOTE_VERSION" ]; then
  printf '{"currentVersion":"%s","latestVersion":null,"updateAvailable":false,"error":"could not read origin/%s:app.json"}\n' "$CURRENT_VERSION" "$BRANCH"
  exit 0
fi

if [ "$CURRENT_VERSION" != "$REMOTE_VERSION" ]; then
  UPDATE_AVAILABLE=true
else
  UPDATE_AVAILABLE=false
fi

printf '{"currentVersion":"%s","latestVersion":"%s","updateAvailable":%s}\n' "$CURRENT_VERSION" "$REMOTE_VERSION" "$UPDATE_AVAILABLE"
