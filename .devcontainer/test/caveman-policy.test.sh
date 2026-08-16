#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$ROOT/.devcontainer/lib/caveman-policy.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f $LIB ]] || fail "caveman-policy library missing"

# Build a workspace fixture. $1 = name, $2 = "skill"|"noskill",
# $3 = "rule"|"norule"|"noagentsmd".
make_ws() {
  local ws="$TMP/$1"
  mkdir -p "$ws"
  [[ $2 == skill ]] && mkdir -p "$ws/.agents/skills/caveman"
  case "$3" in
    rule)       printf 'Respond terse like smart caveman.\n' > "$ws/AGENTS.md" ;;
    norule)     printf 'No style rule here.\n' > "$ws/AGENTS.md" ;;
    noagentsmd) : ;;
  esac
  printf '%s' "$ws"
}

# Run the real function in a `set -euo pipefail` subshell, exactly as
# setup-agents.sh runs it. Captures stdout+stderr and the exit status.
run_check() { # $1 = AGENT_REQUIRE_CAVEMAN value or "__unset__", $2 = workspace
  local out status
  set +e
  out="$(
    if [[ $1 == __unset__ ]]; then unset AGENT_REQUIRE_CAVEMAN
    else export AGENT_REQUIRE_CAVEMAN="$1"; fi
    bash -c '
      set -euo pipefail
      source "$1"
      caveman_policy_check "$2"
    ' _ "$LIB" "$2" 2>&1
  )"
  status=$?
  set -e
  printf '%s' "$out"
  return $status
}

# --- 1. opted-out downstream workspace: silent, exit 0 (issue #65 headline) ---
ws="$(make_ws downstream noskill noagentsmd)"
out="$(run_check __unset__ "$ws")" || fail "opted-out check exited nonzero"
[[ -z "$out" ]] || fail "opted-out workspace produced output: $out"

# --- 2. explicit non-"1" values stay opted out ---
for val in "" 0 no true 11; do
  out="$(run_check "$val" "$ws")" || fail "AGENT_REQUIRE_CAVEMAN=$val exited nonzero"
  [[ -z "$out" ]] || fail "AGENT_REQUIRE_CAVEMAN=$val produced output: $out"
done

# --- 3. opted in, fully configured: confirmation, no WARNING ---
ws="$(make_ws optin-ok skill rule)"
out="$(run_check 1 "$ws")" || fail "opted-in satisfied check exited nonzero"
grep -q 'present for Codex' <<<"$out" || fail "no confirmation line: $out"
grep -q 'WARNING' <<<"$out" && fail "unexpected WARNING when satisfied: $out"

# --- 4. opted in, skill directory missing: WARNING, exit 0 ---
ws="$(make_ws optin-noskill noskill rule)"
out="$(run_check 1 "$ws")" || fail "opted-in missing-skill check exited nonzero"
grep -q 'WARNING' <<<"$out" || fail "expected WARNING for missing skill dir: $out"

# --- 5. opted in, AGENTS.md present but no caveman rule: WARNING, exit 0 ---
ws="$(make_ws optin-norule skill norule)"
out="$(run_check 1 "$ws")" || fail "opted-in missing-rule check exited nonzero"
grep -q 'WARNING' <<<"$out" || fail "expected WARNING for missing rule: $out"

# --- 6. opted in, AGENTS.md absent: WARNING, exit 0 (no set -e abort) ---
ws="$(make_ws optin-noagentsmd skill noagentsmd)"
out="$(run_check 1 "$ws")" || fail "missing AGENTS.md aborted under set -e"
grep -q 'WARNING' <<<"$out" || fail "expected WARNING for absent AGENTS.md: $out"

echo "PASS: caveman policy check"
