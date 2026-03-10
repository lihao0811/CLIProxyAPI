#!/bin/sh
set -e

rm -f /CLIProxyAPI/config.yaml
cp /CLIProxyAPI/railway.yaml /CLIProxyAPI/config.yaml

if [ -n "$PORT" ]; then
    sed -i "s/port: [0-9]*/port: $PORT/" /CLIProxyAPI/config.yaml
fi

cat /CLIProxyAPI/config.yaml

exec ./CLIProxyAPI
