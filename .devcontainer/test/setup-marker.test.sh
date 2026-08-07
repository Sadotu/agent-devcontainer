#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$ROOT/.devcontainer/lib/setup-marker.sh"
SETUP="$ROOT/.devcontainer/setup-agents.sh"
DOCKERFILE="$ROOT/.devcontainer/Dockerfile"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f $LIB ]] || fail "setup-marker library missing"

# --- path resolution: default and override ---
( unset AGENT_SETUP_MARKER; source "$LIB"
  [[ "$(setup_marker_path)" == "/run/agent-devcontainer/agent-setup-complete" ]] ) \
  || fail "default marker path wrong"
( AGENT_SETUP_MARKER="$TMP/custom"; source "$LIB"
  [[ "$(setup_marker_path)" == "$TMP/custom" ]] ) \
  || fail "override marker path wrong"

# --- reset removes a stale marker and no-ops when absent ---
MARKER="$TMP/run/agent-setup-complete"
mkdir -p "$TMP/run"; echo stale > "$MARKER"
( AGENT_SETUP_MARKER="$MARKER"; source "$LIB"; setup_marker_reset )
[[ -e "$MARKER" ]] && fail "reset did not remove stale marker"
( AGENT_SETUP_MARKER="$MARKER"; source "$LIB"; setup_marker_reset ) \
  || fail "reset errored when marker absent"

# --- complete creates the marker atomically, mode 644, non-empty ---
( AGENT_SETUP_MARKER="$MARKER"; source "$LIB"; setup_marker_complete )
[[ -f "$MARKER" ]] || fail "complete did not create marker"
[[ -s "$MARKER" ]] || fail "marker is empty"
mode="$(stat -c '%a' "$MARKER")"
[[ "$mode" == "644" ]] || fail "marker mode is $mode, expected 644"
# no temp leftovers in the marker directory
leftovers="$(find "$TMP/run" -type f ! -name 'agent-setup-complete')"
[[ -z "$leftovers" ]] || fail "temp leftovers after complete: $leftovers"

# --- complete creates the parent dir if missing ---
DEEP="$TMP/deep/nested/marker"
( AGENT_SETUP_MARKER="$DEEP"; source "$LIB"; setup_marker_complete )
[[ -f "$DEEP" ]] || fail "complete did not create missing parent dir"

# --- failure path: set -e aborts before complete -> marker absent ---
FAILMARK="$TMP/run/fail-marker"
set +e
AGENT_SETUP_MARKER="$FAILMARK" bash -c '
  set -euo pipefail
  source "'"$LIB"'"
  setup_marker_reset
  false            # simulates a required setup step failing
  setup_marker_complete
'
rc=$?
set -e
[[ $rc -ne 0 ]] || fail "failure-path wrapper unexpectedly succeeded"
[[ -e "$FAILMARK" ]] && fail "marker written despite failed setup"

# --- structural guard on setup-agents.sh wiring ---
grep -q 'source .*lib/setup-marker.sh' "$SETUP" || fail "setup-agents.sh does not source the marker lib"
# `|| true`: a missing pattern is exactly what the `[[ -n ... ]]` guards below
# are meant to report — without it, grep's exit 1 under `set -o pipefail` would
# abort via `set -e` before the descriptive `fail` message (the CLAUDE.md
# trailing-grep pipefail gotcha).
reset_line="$(grep -n '^setup_marker_reset' "$SETUP" | head -1 | cut -d: -f1 || true)"
complete_line="$(grep -n '^setup_marker_complete' "$SETUP" | head -1 | cut -d: -f1 || true)"
first_work="$(grep -n 'Fixing ownership of persisted config volumes' "$SETUP" | head -1 | cut -d: -f1)"
checklist="$(grep -n 'Manual checklist' "$SETUP" | head -1 | cut -d: -f1)"
[[ -n "$reset_line" ]] || fail "setup-agents.sh never calls setup_marker_reset"
[[ -n "$complete_line" ]] || fail "setup-agents.sh never calls setup_marker_complete"
[[ "$reset_line" -lt "$first_work" ]] || fail "setup_marker_reset not called before first work step"
[[ "$complete_line" -gt "$checklist" ]] || fail "setup_marker_complete not the final action (before checklist)"

# --- image provides a writable runtime directory without changing /run ---
grep -Eq 'mkdir -p( -m [0-9]+)? /run/agent-devcontainer' "$DOCKERFILE" \
  || fail "Dockerfile does not create marker directory"
grep -Eq 'chown( -R)? vscode:vscode /run/agent-devcontainer' "$DOCKERFILE" \
  || fail "Dockerfile does not give vscode ownership of marker directory"

echo "PASS: setup completion marker"
