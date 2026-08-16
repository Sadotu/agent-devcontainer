#!/usr/bin/env bash
# Caveman policy check for setup-agents.sh. Sourced, not executed.
#
# Caveman is a response-style preference, not setup readiness: Claude Code
# gets the plugin from the container-level `claude plugin install`, and Codex
# reads .agents/skills/ natively whether or not a repository opts in. Warning
# every downstream workspace that lacked the skill + AGENTS.md activation rule
# told operators setup was incomplete when it wasn't (issue #65).
#
# The check now runs only for workspaces that explicitly declare the policy
# via AGENT_REQUIRE_CAVEMAN=1 (set from devcontainer.json containerEnv).
# It stays advisory: it never returns nonzero and never fails setup.

# caveman_policy_check <workspace-dir>
caveman_policy_check() {
  local workspace="$1"

  [ "${AGENT_REQUIRE_CAVEMAN:-}" = "1" ] || return 0

  # `grep -qi` with 2>/dev/null: a missing AGENTS.md is an ordinary false here,
  # and the `if` context keeps its nonzero exit from tripping the caller's
  # `set -e`.
  if [ -d "$workspace/.agents/skills/caveman" ] &&
     grep -qi "caveman" "$workspace/AGENTS.md" 2>/dev/null; then
    echo "    caveman skill + AGENTS.md activation rule present for Codex."
  else
    echo "WARNING: AGENT_REQUIRE_CAVEMAN=1 but the caveman skill or the"
    echo "         AGENTS.md activation rule is missing — check"
    echo "         $workspace/.agents/skills/caveman and $workspace/AGENTS.md"
  fi
  return 0
}
