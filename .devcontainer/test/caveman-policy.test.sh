#!/usr/bin/env bash
# Covers the Caveman policy check (issue #65): no project opts in or is
# asked — the check runs unconditionally, stays silent when Caveman is
# already active, and warns only when it is not.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$ROOT/.devcontainer/lib/caveman-policy.sh"
SETUP="$ROOT/.devcontainer/setup-agents.sh"
DOCKERFILE="$ROOT/.devcontainer/Dockerfile"
TEMPLATE="$ROOT/.devcontainer/devcontainer.json.template"
DEVCONTAINER="$ROOT/.devcontainer/devcontainer.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f $LIB ]] || fail "caveman-policy library missing"

# make_workspace <name> <skill|no-skill> <rule|no-rule|no-file> -> prints path
make_workspace() {
  local ws="$TMP/$1"
  rm -rf "$ws"; mkdir -p "$ws"
  if [ "$2" = skill ]; then mkdir -p "$ws/.agents/skills/caveman"; fi
  case "$3" in
    rule)    printf 'Respond terse like smart caveman.\n' > "$ws/AGENTS.md" ;;
    no-rule) printf '# Agent Instructions\n' > "$ws/AGENTS.md" ;;
    no-file) ;;
  esac
  printf '%s' "$ws"
}

# run_check <workspace>
# The check runs under `set -e` in a subshell, so a check that aborts its
# caller loses the trailing marker and shows up as a failure. Sets OUT and RC.
run_check() {
  local ws="$1"
  set +e
  OUT="$(bash -c '
    set -euo pipefail
    source "$1"
    caveman_policy_check "$2"
    echo RC_MARKER_OK
  ' bash "$LIB" "$ws" 2>&1)"
  RC=$?
  set -e
}

# --- Active: skill + AGENTS.md rule present -> silent -----------------------
ws_full="$(make_workspace active skill rule)"
run_check "$ws_full"
[[ $RC -eq 0 ]] || fail "active workspace: exit $RC, expected 0"
[[ "$OUT" == "RC_MARKER_OK" ]] || fail "active workspace printed: $OUT"

# --- Not active -> warns, but never aborts the caller, and no opt-in needed -
for scenario in "skill-missing:no-skill:rule" "rule-missing:skill:no-rule" "agents-md-missing:skill:no-file" "downstream:no-skill:no-file"; do
  IFS=: read -r name skill rule <<<"$scenario"
  ws_bad="$(make_workspace "$name" "$skill" "$rule")"
  run_check "$ws_bad"
  [[ $RC -eq 0 ]] || fail "$name: exit $RC, expected 0 (the check must stay non-fatal)"
  [[ "$OUT" == *"WARNING: caveman skill or AGENTS.md activation rule missing"* ]] \
    || fail "$name did not warn: $OUT"
  [[ "$OUT" == *RC_MARKER_OK* ]] || fail "$name aborted the caller under set -e: $OUT"
done

# --- Wiring: setup-agents.sh delegates and keeps no inline copy ---------------
grep -q 'source .*lib/caveman-policy.sh' "$SETUP" || fail "setup-agents.sh does not source the caveman-policy lib"
grep -q 'caveman_policy_check "\$WORKSPACE"' "$SETUP" || fail "setup-agents.sh does not call caveman_policy_check"
# `|| true`: no match is the passing case here, and a bare trailing grep under
# `set -o pipefail` would abort via `set -e` before the descriptive fail.
inline="$(grep -n 'WARNING: caveman' "$SETUP" || true)"
[[ -z "$inline" ]] || fail "setup-agents.sh still warns inline: $inline"

# --- Wiring: baked into the image; no opt-in flag anywhere -------------------
grep -q 'COPY lib/caveman-policy.sh /opt/agent-devcontainer/lib/caveman-policy.sh' "$DOCKERFILE" \
  || fail "Dockerfile does not bake the caveman-policy lib"
template_optin="$(grep -n 'REQUIRE_CAVEMAN' "$TEMPLATE" || true)"
[[ -z "$template_optin" ]] \
  || fail "devcontainer.json.template still references REQUIRE_CAVEMAN — no project should have to opt in: $template_optin"
devcontainer_optin="$(grep -n 'REQUIRE_CAVEMAN' "$DEVCONTAINER" || true)"
[[ -z "$devcontainer_optin" ]] \
  || fail "this repo's devcontainer.json still sets REQUIRE_CAVEMAN — the check no longer needs it: $devcontainer_optin"
lib_optin="$(grep -n 'REQUIRE_CAVEMAN' "$LIB" || true)"
[[ -z "$lib_optin" ]] \
  || fail "caveman-policy.sh still references REQUIRE_CAVEMAN: $lib_optin"

echo "PASS: caveman policy check runs unconditionally, warns only when inactive"
