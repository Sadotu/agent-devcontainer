#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 WORKSPACE TOOL_DIRECTORY" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage
workspace="$1"
tool_directory="$2"

cp -n "$tool_directory/agents.toml" "$workspace/agents.toml" 2>/dev/null

(cd "$workspace" && npx -y @sentry/dotagents@3.0.1 --project install)
