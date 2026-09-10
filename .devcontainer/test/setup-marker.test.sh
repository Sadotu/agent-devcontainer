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

# Exercise setup's real reporting functions without running external setup
# operations. A missing warning outcome or EXIT cleanup breaks user-visible
# optional/required failure reporting even when marker plumbing still works.
stage_preamble() {
  sed -n '/^STAGE_ACTIVE=0$/,/^trap .*stage_on_exit.* EXIT$/p' "$SETUP"
}

OUT="$(
  source <(stage_preamble)
  stage_begin "Optional setup work"
  STAGE_WARNINGS=1
  stage_end
  trap - EXIT
  exit 0
  )" || fail "optional stage probe failed ($OUT)"
grep -Eq '^==> Optional setup work completed with warnings in [0-9]+s$' <<<"$OUT" \
  || fail "optional stage did not report warning outcome ($OUT)"

set +e
OUT="$(
  (
    source <(stage_preamble)
    stage_begin "Required setup work"
    printf 'bounded setup diagnostic\n' >&2
    exit 29
  ) 2>&1
)"
rc=$?
set -e
[[ $rc -eq 29 ]] || fail "required setup stage returned $rc instead of 29 ($OUT)"
grep -Fq 'bounded setup diagnostic' <<<"$OUT" || fail "required setup diagnostic was hidden ($OUT)"
grep -Eq 'Required setup work failed after [0-9]+s \(exit 29\)' <<<"$OUT" \
  || fail "required setup failure omitted stage, elapsed time, or status ($OUT)"

# A signal delivered to the reporting shell must not reuse the previous
# successful command's status in its failure diagnostic.
stage_preamble >"$TMP/stage-preamble.sh"
set +e
OUT="$(bash -c '
  set -euo pipefail
  source "$1"
  stage_begin "Signaled setup work"
  kill -TERM "$$"
' bash "$TMP/stage-preamble.sh" 2>&1)"
rc=$?
set -e
[[ $rc -eq 143 ]] || fail "signaled setup stage returned $rc instead of 143 ($OUT)"
grep -Eq 'Signaled setup work failed after [0-9]+s \(exit 143\)' <<<"$OUT" \
  || fail "setup signal diagnostic reported the previous command status ($OUT)"

# --- structural guard on setup-agents.sh wiring ---
grep -q 'source .*lib/setup-marker.sh' "$SETUP" || fail "setup-agents.sh does not source the marker lib"
# `|| true`: a missing pattern is exactly what the `[[ -n ... ]]` guards below
# are meant to report — without it, grep's exit 1 under `set -o pipefail` would
# abort via `set -e` before the descriptive `fail` message (the CLAUDE.md
# trailing-grep pipefail gotcha).
reset_line="$(grep -n '^setup_marker_reset' "$SETUP" | head -1 | cut -d: -f1 || true)"
complete_line="$(grep -n '^setup_marker_complete' "$SETUP" | head -1 | cut -d: -f1 || true)"
setup_done_line="$(grep -n '^echo "==> Setup complete' "$SETUP" | head -1 | cut -d: -f1 || true)"
premature_done="$(grep -n '^echo "==> Done' "$SETUP" || true)"
first_work="$(grep -n 'Fixing ownership of persisted config volumes' "$SETUP" | head -1 | cut -d: -f1)"
checklist="$(grep -n 'Manual checklist' "$SETUP" | head -1 | cut -d: -f1)"
[[ -n "$reset_line" ]] || fail "setup-agents.sh never calls setup_marker_reset"
[[ -n "$complete_line" ]] || fail "setup-agents.sh never calls setup_marker_complete"
[[ -n "$setup_done_line" ]] || fail "setup-agents.sh never reports setup completion"
[[ -z "$premature_done" ]] || fail "setup-agents.sh still reports premature Done before readiness publication"
[[ "$reset_line" -lt "$first_work" ]] || fail "setup_marker_reset not called before first work step"
[[ "$complete_line" -gt "$checklist" ]] || fail "setup_marker_complete runs before checklist finishes"
[[ "$complete_line" -lt "$setup_done_line" ]] || fail "setup completion is reported before readiness marker publication"
for stage in "Configuring credentials" "Updating agent packages" "Updating skills and plugins"; do
  grep -Fq "stage_begin \"$stage\"" "$SETUP" || fail "setup omits $stage stage"
done

# --- image provides a writable runtime directory without changing /run ---
grep -Eq 'mkdir -p( -m [0-9]+)? /run/agent-devcontainer' "$DOCKERFILE" \
  || fail "Dockerfile does not create marker directory"
grep -Eq 'chown( -R)? vscode:vscode /run/agent-devcontainer' "$DOCKERFILE" \
  || fail "Dockerfile does not give vscode ownership of marker directory"

echo "PASS: setup completion marker"
