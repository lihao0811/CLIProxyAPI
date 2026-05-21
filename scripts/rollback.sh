#!/bin/sh
# Roll back to the most recent backup snapshot, or a specific one if passed.
#
# Usage:
#   scripts/rollback.sh                # use most recent
#   scripts/rollback.sh 20260508-043503  # use named timestamp
set -e

REPO_DIR="${REPO_DIR:-/data/CLIProxyAPI}"
TARGET="$1"

if [ -z "$TARGET" ]; then
  TARGET="$(ls -1t "$REPO_DIR/.backup" 2>/dev/null | head -1)"
fi

if [ -z "$TARGET" ]; then
  echo "ERROR: no backup found under $REPO_DIR/.backup" >&2
  exit 1
fi

BAK="$REPO_DIR/.backup/$TARGET"
RESTORE="$BAK/RESTORE.sh"

if [ ! -x "$RESTORE" ]; then
  echo "ERROR: $RESTORE not found or not executable" >&2
  echo "available backups:" >&2
  ls -1 "$REPO_DIR/.backup" 2>/dev/null >&2
  exit 1
fi

echo "rolling back from $BAK"
exec sh "$RESTORE"
