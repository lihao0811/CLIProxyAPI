#!/bin/sh
# Snapshot the live production setup before any deploy/upgrade.
#
# Captures, into /data/CLIProxyAPI/.backup/<timestamp>/:
#   - docker-compose.yml, railway.yaml, .env, Makefile, config.yaml (current files)
#   - container-inspect.json (full docker inspect of cli-proxy-api)
#   - git-head.txt, git-status.txt
#   - RESTORE.sh (a self-contained one-shot rollback script)
# Also retags the running production image as cliproxyapi-rollback:<timestamp>
# so it survives an `docker pull` overwrite of :latest.
set -e

REPO_DIR="${REPO_DIR:-/data/CLIProxyAPI}"
TS="$(date +%Y%m%d-%H%M%S)"
BAK="$REPO_DIR/.backup/$TS"
CONTAINER="${CONTAINER:-cli-proxy-api}"

mkdir -p "$BAK"
cd "$REPO_DIR"

# Config files (best-effort; a missing file is not fatal)
for f in docker-compose.yml railway.yaml .env Makefile config.yaml docker-compose.uat.yml; do
  [ -f "$f" ] && cp "$f" "$BAK/" || true
done

# Container state — only snapshot if the container exists
if docker inspect "$CONTAINER" >/dev/null 2>&1; then
  docker inspect "$CONTAINER" > "$BAK/container-inspect.json"
  CURRENT_IMAGE="$(docker inspect "$CONTAINER" --format '{{.Config.Image}}')"
  echo "$CURRENT_IMAGE" > "$BAK/current-image.txt"
  # Retag the image we are running so :latest can be overwritten without losing it
  docker tag "$CURRENT_IMAGE" "cliproxyapi-rollback:$TS"
fi

# Git state
git rev-parse HEAD > "$BAK/git-head.txt" 2>/dev/null || true
git status > "$BAK/git-status.txt" 2>/dev/null || true

# Self-contained restore script
cat > "$BAK/RESTORE.sh" <<RESTORE
#!/bin/sh
# Restore production to the state captured at $TS.
# Run from any directory.
set -e
SRC="$BAK"
REPO="$REPO_DIR"
cd "\$REPO"

echo "[rollback] stopping current containers"
docker compose -f docker-compose.yml down 2>/dev/null || true
docker compose -f docker-compose.uat.yml down 2>/dev/null || true

echo "[rollback] restoring files from \$SRC"
for f in docker-compose.yml railway.yaml .env Makefile config.yaml docker-compose.uat.yml; do
  [ -f "\$SRC/\$f" ] && cp -f "\$SRC/\$f" "\$REPO/\$f" || true
done

if [ -f "\$SRC/current-image.txt" ]; then
  ORIG_IMAGE="\$(cat "\$SRC/current-image.txt")"
  echo "[rollback] retagging cliproxyapi-rollback:$TS -> \$ORIG_IMAGE"
  docker tag "cliproxyapi-rollback:$TS" "\$ORIG_IMAGE"
fi

echo "[rollback] starting cli-proxy-api with restored compose"
docker compose -f docker-compose.yml up -d

sleep 5
docker ps --format '{{.Names}}\t{{.Status}}' | grep cli-proxy-api || true
RESTORE
chmod +x "$BAK/RESTORE.sh"

echo "=== backup created: $BAK ==="
ls -la "$BAK/"
echo
echo "Rollback with:  sh $BAK/RESTORE.sh"
