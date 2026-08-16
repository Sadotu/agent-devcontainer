#!/usr/bin/env bash
# Caveman policy check for setup-agents.sh (issue #65). Sourced, not executed.
#
# No project has to declare or ask for this — it runs unconditionally on
# every workspace. It is purely a readiness signal: if Caveman is already
# active (skill files in .agents/skills/caveman, plus the always-on
# activation rule in AGENTS.md — Codex reads .agents/skills/ natively), stay
# silent. Only speak up when Caveman is NOT active, so an incomplete setup is
# visible without nagging every project that never adopted Caveman.
#
# Advisory only — it never returns nonzero, so it can never abort setup's
# `set -e`. Required auth/readiness checks remain the only fail-closed paths.

caveman_policy_check() {
  local workspace="$1"

  if [ -d "$workspace/.agents/skills/caveman" ] &&
     grep -qi "caveman" "$workspace/AGENTS.md" 2>/dev/null; then
    return 0
  fi

  echo "WARNING: caveman skill or AGENTS.md activation rule missing — check"
  echo "         $workspace/.agents/skills/caveman and $workspace/AGENTS.md"
  return 0
}
