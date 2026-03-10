#!/bin/sh
set -e

export PGSTORE_DSN="postgresql://postgres:kzknCJHVzfYZZNYskUJhvyJkOdyjeSTI@postgres-cjmj.railway.internal:5432/railway"
export PGSTORE_SCHEMA="public"
export PGSTORE_LOCAL_PATH="/data/pgstore"

# 强制使用 railway.yaml
rm -f /CLIProxyAPI/config.yaml
cp /CLIProxyAPI/railway.yaml /CLIProxyAPI/config.yaml

if [ -n "$PORT" ]; then
    sed -i "s/port: [0-9]*/port: $PORT/" /CLIProxyAPI/config.yaml
fi

exec ./CLIProxyAPI
