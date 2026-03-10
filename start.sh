#!/bin/sh
set -e

# Railway 会设置 PORT 环境变量
if [ -n "$PORT" ]; then
    echo "Using PORT from environment: $PORT"
    sed -i "s/port: 8317/port: $PORT/" /CLIProxyAPI/config.yaml
fi

exec ./CLIProxyAPI
