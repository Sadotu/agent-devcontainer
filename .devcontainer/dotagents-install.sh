#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 [--upgrade] WORKSPACE TOOL_DIRECTORY" >&2
  exit 2
}

upgrade=false
if [[ "${1:-}" == "--upgrade" ]]; then
  upgrade=true
  shift
fi

[[ $# -eq 2 ]] || usage
workspace="$1"
tool_directory="$2"

cp -n "$tool_directory/agents.toml" "$workspace/agents.toml" 2>/dev/null

install_args=(install)
if [[ "$upgrade" == false && -f "$workspace/agents.lock" ]]; then
  install_args+=(--frozen)
fi

(cd "$workspace" && npx -y @sentry/dotagents@1.17.0 "${install_args[@]}")
