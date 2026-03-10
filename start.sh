#!/bin/sh
set -e

if [ ! -f /CLIProxyAPI/config.yaml ]; then
    cp /CLIProxyAPI/railway.yaml /CLIProxyAPI/config.yaml
fi

if [ -n "$PORT" ]; then
    sed -i "s/port: [0-9]*/port: $PORT/" /CLIProxyAPI/config.yaml
fi

exec ./CLIProxyAPI
