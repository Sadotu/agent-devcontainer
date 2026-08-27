#!/usr/bin/env bash
# Covers the deny-merge PreToolUse hook (#95): blocks `gh pr merge`,
# PUT-to-merge API calls, and `git push` to a protected branch; tolerates
# a payload with no `.tool_input.command`; allows everything else.
set -euo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/deny-merge.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -x $HOOK ]] || fail "deny-merge.sh missing or not executable"

# run_hook <command-json-value-or-omit> -> sets RC, ERR
# pass "" to omit .tool_input.command entirely
run_hook() {
  local cmd="$1" payload
  if [ -n "$cmd" ]; then
    payload="$(jq -n --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')"
  else
    payload='{"tool_name":"Bash","tool_input":{}}'
  fi
  set +e
  ERR="$(printf '%s' "$payload" | "$HOOK" 2>&1 >/dev/null)"
  RC=$?
  set -e
}

# --- blocked: gh pr merge -----------------------------------------------------
run_hook "gh pr merge 1"
[ "$RC" -eq 2 ] || fail "gh pr merge 1: exit $RC, expected 2"
[ -n "$ERR" ] || fail "gh pr merge 1: no reason on stderr"

run_hook "gh pr merge 5 --squash"
[ "$RC" -eq 2 ] || fail "gh pr merge 5 --squash: exit $RC, expected 2"

run_hook "gh --repo Sadotu/agent-devcontainer pr merge 5"
[ "$RC" -eq 2 ] || fail "gh --repo ... pr merge 5: exit $RC, expected 2"

# --- blocked: PUT to a pulls/<n>/merge API path -------------------------------
run_hook "gh api -X PUT repos/Sadotu/agent-devcontainer/pulls/5/merge"
[ "$RC" -eq 2 ] || fail "gh api -X PUT .../pulls/5/merge: exit $RC, expected 2"

run_hook "curl --method PUT https://api.github.com/repos/Sadotu/agent-devcontainer/pulls/5/merge"
[ "$RC" -eq 2 ] || fail "curl --method PUT .../pulls/5/merge: exit $RC, expected 2"

# --- blocked: git push to a protected branch ----------------------------------
run_hook "git push origin main"
[ "$RC" -eq 2 ] || fail "git push origin main: exit $RC, expected 2"

run_hook "git push origin HEAD:main"
[ "$RC" -eq 2 ] || fail "git push origin HEAD:main: exit $RC, expected 2"

run_hook "git push upstream develop"
[ "$RC" -eq 2 ] || fail "git push upstream develop: exit $RC, expected 2"

# --- allowed: unrelated commands ----------------------------------------------
run_hook "git status"
[ "$RC" -eq 0 ] || fail "git status: exit $RC, expected 0"

run_hook "git push origin agent/95-deny-merge-hook"
[ "$RC" -eq 0 ] || fail "git push origin agent/95-deny-merge-hook: exit $RC, expected 0 (not a protected branch)"

run_hook "gh pr view 5"
[ "$RC" -eq 0 ] || fail "gh pr view 5: exit $RC, expected 0"

# --- tolerates a payload with no command ---------------------------------------
run_hook ""
[ "$RC" -eq 0 ] || fail "no .tool_input.command: exit $RC, expected 0"

echo "PASS: deny-merge hook blocks pr merge / PUT-merge / protected-branch push, allows the rest"
