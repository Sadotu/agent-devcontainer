#!/usr/bin/env bash
# Opt-in Caveman policy check for setup-agents.sh (issue #65). Sourced, not
# executed.
#
# Caveman is a response-style preference, not a setup-readiness requirement, so
# this stays silent unless the workspace has explicitly declared the policy by
# setting REQUIRE_CAVEMAN=1 in its devcontainer.json containerEnv. Repos that
# do declare it get the same validation as before: the skill files must live in
# .agents/skills/caveman (Codex reads .agents/skills/ natively) and the
# always-on activation rule must be in AGENTS.md.
#
# Advisory only — it never returns nonzero, so it can never abort setup's
# `set -e`. Required auth/readiness checks remain the only fail-closed paths.

caveman_policy_check() {
  local workspace="$1"

  [ "${REQUIRE_CAVEMAN:-}" = 1 ] || return 0

  if [ -d "$workspace/.agents/skills/caveman" ] &&
     grep -qi "caveman" "$workspace/AGENTS.md" 2>/dev/null; then
    echo "    caveman skill + AGENTS.md activation rule present for Codex."
  else
    echo "WARNING: caveman skill or AGENTS.md activation rule missing — check"
    echo "         $workspace/.agents/skills/caveman and $workspace/AGENTS.md"
  fi
  return 0
}
