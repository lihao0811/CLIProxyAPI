#!/bin/sh
set -e

if [ ! -f /CLIProxyAPI/config.yaml ]; then
    cp /CLIProxyAPI/config.example.yaml /CLIProxyAPI/config.yaml
fi

# 强制启用远程管理
sed -i 's/allow-remote: false/allow-remote: true/' /CLIProxyAPI/config.yaml
sed -i 's/secret-key: ""/secret-key: "railway-default-password"/' /CLIProxyAPI/config.yaml

if [ -n "$PORT" ]; then
    sed -i "s/port: [0-9]*/port: $PORT/" /CLIProxyAPI/config.yaml
fi

exec ./CLIProxyAPI
