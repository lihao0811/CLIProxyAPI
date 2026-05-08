#!/bin/sh
# Pull the latest cnb image. If pull fails or image digest is unchanged,
# the container is NOT recreated. Only when there is actually a new image
# will the container be restarted (with healthcheck wait).
#
# Use FORCE=1 sh scripts/deploy.sh to recreate the container even when
# the image digest is unchanged (useful when only docker-compose.yml or
# .env changed).
set -e

REPO_DIR="${REPO_DIR:-/data/CLIProxyAPI}"
IMAGE_REF="${IMAGE_REF:-docker.cnb.cool/jung.ren/cliproxyapi:latest}"
FORCE="${FORCE:-0}"
cd "$REPO_DIR"

echo "[deploy] step 1: backup current state"
sh "$REPO_DIR/scripts/backup.sh"
echo

echo "[deploy] step 2: ensure mount dirs exist"
mkdir -p ./logs ./data/auth ./data/usage

echo "[deploy] step 3: record current image id"
OLD_ID="$(docker image inspect "$IMAGE_REF" --format '{{.Id}}' 2>/dev/null || echo none)"
echo "  old: $OLD_ID"

echo "[deploy] step 4: docker compose pull"
if ! docker compose -f docker-compose.yml pull; then
  echo "[deploy] ERROR: pull failed, container NOT restarted"
  exit 1
fi

NEW_ID="$(docker image inspect "$IMAGE_REF" --format '{{.Id}}')"
echo "  new: $NEW_ID"

if [ "$OLD_ID" = "$NEW_ID" ] && [ "$FORCE" != "1" ]; then
  echo "[deploy] no image update, container NOT restarted"
  echo "[deploy] (run with FORCE=1 to recreate anyway, e.g. when compose/env changed)"
  exit 0
fi

if [ "$OLD_ID" = "$NEW_ID" ]; then
  echo "[deploy] image unchanged but FORCE=1, will recreate"
else
  echo "[deploy] image updated, will recreate"
fi

echo "[deploy] step 5: docker compose up -d (recreates the container)"
docker compose -f docker-compose.yml up -d

echo
echo "[deploy] step 6: wait for healthcheck (up to 90s)"
for i in $(seq 1 18); do
  STATE="$(docker inspect cli-proxy-api --format '{{.State.Health.Status}}' 2>/dev/null || echo unknown)"
  echo "  attempt $i: $STATE"
  if [ "$STATE" = "healthy" ]; then
    echo "[deploy] OK, container healthy"
    docker ps --format '{{.Names}}\t{{.Status}}' | grep cli-proxy-api
    exit 0
  fi
  sleep 5
done

echo "[deploy] WARNING: container not healthy after 90s"
echo "[deploy] tail of container logs:"
docker logs --tail 30 cli-proxy-api
echo
echo "[deploy] to roll back: sh $REPO_DIR/scripts/rollback.sh"
exit 1
