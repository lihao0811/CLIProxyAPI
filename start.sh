#!/bin/sh
set -e

rm -f /CLIProxyAPI/config.yaml
cp /CLIProxyAPI/railway.yaml /CLIProxyAPI/config.yaml

exec ./CLIProxyAPI
