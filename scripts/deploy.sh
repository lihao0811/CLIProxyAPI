#!/bin/sh
# Pull the latest cnb image, recreate cli-proxy-api, wait for healthcheck.
# Always takes a backup snapshot first.
set -e

REPO_DIR="${REPO_DIR:-/data/CLIProxyAPI}"
cd "$REPO_DIR"

echo "[deploy] step 1: backup current state"
sh "$REPO_DIR/scripts/backup.sh"
echo

echo "[deploy] step 2: ensure logs and usage dirs exist"
mkdir -p ./logs ./data/auth ./data/usage

echo "[deploy] step 3: docker compose pull"
docker compose -f docker-compose.yml pull

echo "[deploy] step 4: docker compose up -d (recreates the container)"
docker compose -f docker-compose.yml up -d

echo
echo "[deploy] step 5: wait for healthcheck (up to 90s)"
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
