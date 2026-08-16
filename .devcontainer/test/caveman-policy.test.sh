#!/usr/bin/env bash
# Covers the opt-in Caveman policy check (issue #65): silent for every
# workspace that has not declared Caveman required, and still able to validate
# the policy for a workspace that has.
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

# run_check <workspace> [REQUIRE_CAVEMAN value; unset when omitted]
# The check runs under `set -e` in a subshell, so a check that aborts its
# caller loses the trailing marker and shows up as a failure. Sets OUT and RC.
run_check() {
  local ws="$1"
  local -a env_prefix=(env -u REQUIRE_CAVEMAN)
  if [ "$#" -ge 2 ]; then env_prefix=(env "REQUIRE_CAVEMAN=$2"); fi
  set +e
  OUT="$("${env_prefix[@]}" bash -c '
    set -euo pipefail
    source "$1"
    caveman_policy_check "$2"
    echo RC_MARKER_OK
  ' bash "$LIB" "$ws" 2>&1)"
  RC=$?
  set -e
}

# --- Not opted in: silent, regardless of what the workspace contains ---------
ws="$(make_workspace downstream no-skill no-file)"
run_check "$ws"
[[ $RC -eq 0 ]] || fail "unset REQUIRE_CAVEMAN: exit $RC, expected 0"
[[ "$OUT" == "RC_MARKER_OK" ]] || fail "unset REQUIRE_CAVEMAN printed: $OUT"

for value in "" 0 no false 11 " 1"; do
  run_check "$ws" "$value"
  [[ $RC -eq 0 ]] || fail "REQUIRE_CAVEMAN='$value': exit $RC, expected 0"
  [[ "$OUT" == "RC_MARKER_OK" ]] || fail "REQUIRE_CAVEMAN='$value' printed: $OUT"
done

# A workspace that happens to ship the skill but never opted in stays silent.
ws_full="$(make_workspace optedout-but-present skill rule)"
run_check "$ws_full"
[[ "$OUT" == "RC_MARKER_OK" ]] || fail "opted-out workspace with skill printed: $OUT"

# --- Opted in: policy satisfied ---------------------------------------------
run_check "$ws_full" 1
[[ $RC -eq 0 ]] || fail "opted-in satisfied: exit $RC, expected 0"
[[ "$OUT" == *"caveman skill + AGENTS.md activation rule present"* ]] \
  || fail "opted-in satisfied did not confirm the policy: $OUT"
if [[ "$OUT" == *WARNING* ]]; then fail "opted-in satisfied warned anyway: $OUT"; fi

# --- Opted in: policy unmet -> warns, but never aborts the caller ------------
for scenario in "skill-missing:no-skill:rule" "rule-missing:skill:no-rule" "agents-md-missing:skill:no-file"; do
  IFS=: read -r name skill rule <<<"$scenario"
  ws_bad="$(make_workspace "$name" "$skill" "$rule")"
  run_check "$ws_bad" 1
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

# --- Wiring: baked into the image; opt-in absent from the downstream template -
grep -q 'COPY lib/caveman-policy.sh /opt/agent-devcontainer/lib/caveman-policy.sh' "$DOCKERFILE" \
  || fail "Dockerfile does not bake the caveman-policy lib"
template_optin="$(grep -n 'REQUIRE_CAVEMAN' "$TEMPLATE" || true)"
[[ -z "$template_optin" ]] \
  || fail "devcontainer.json.template sets REQUIRE_CAVEMAN — new projects must default to silent: $template_optin"
grep -q '"REQUIRE_CAVEMAN": "1"' "$DEVCONTAINER" \
  || fail "this repo's devcontainer.json does not opt in, though AGENTS.md declares the policy"

echo "PASS: opt-in caveman policy check"
