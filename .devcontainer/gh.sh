#!/usr/bin/env bash
set -eu
set +x

token="$(/opt/agent-devcontainer/gh-app-token.sh)"
GH_TOKEN="$token" exec /usr/bin/gh "$@"
