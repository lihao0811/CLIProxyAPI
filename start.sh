#!/bin/sh
set -e

rm -f /CLIProxyAPI/config.yaml
cp /CLIProxyAPI/railway.yaml /CLIProxyAPI/config.yaml

# Best-effort: launch the usage collector in the background. A failure here
# (missing secret, write permission, etc.) must never block the proxy from
# starting, so we log to stdout and continue.
if [ -n "${COLLECTOR_SECRET}" ]; then
  echo "[start.sh] launching usage collector (output dir: ${COLLECTOR_OUTPUT_DIR:-/data/usage})"
  /CLIProxyAPI/cpa-usage-collector &
else
  echo "[start.sh] COLLECTOR_SECRET not set, usage collector disabled"
fi

exec ./CLIProxyAPI
