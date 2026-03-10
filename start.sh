#!/bin/sh
set -e

# 如果 config.yaml 不存在，从示例创建
if [ ! -f /CLIProxyAPI/config.yaml ]; then
    cp /CLIProxyAPI/config.example.yaml /CLIProxyAPI/config.yaml
fi

# Railway 会设置 PORT 环境变量
if [ -n "$PORT" ]; then
    echo "Using PORT from environment: $PORT"
    sed -i "s/port: 8317/port: $PORT/" /CLIProxyAPI/config.yaml
fi

exec ./CLIProxyAPI
