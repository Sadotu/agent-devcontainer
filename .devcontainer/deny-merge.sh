#!/usr/bin/env bash
# Claude Code PreToolUse hook (matcher: Bash) — the local backstop against a
# PR merge or a direct push to a protected branch, now that branch
# protection on the Git server is unavailable (private repo, free-plan org).
# See CLAUDE.md "Git & PR policy" / #95.
#
# Reads the tool payload on stdin, exits 2 with a reason on stderr to block
# the command, exits 0 (including on a payload with no .tool_input.command)
# to allow it.
set -u

command="$(jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$command" ] || exit 0

if grep -Eq '\bgh\b.*\bpr\b.*\bmerge\b' <<<"$command"; then
  echo "BLOCKED: 'gh pr merge' is not allowed from this workspace — merging is a repository-owner action." >&2
  exit 2
fi

if grep -Eq 'pulls/[0-9]+/merge' <<<"$command" && grep -Eq '\bPUT\b' <<<"$command"; then
  echo "BLOCKED: a PUT to the pulls/<n>/merge API is not allowed from this workspace — merging is a repository-owner action." >&2
  exit 2
fi

if grep -Eq '\bgit[[:space:]]+push\b' <<<"$command" \
    && grep -Eq '\b(main|master|develop)\b' <<<"$command"; then
  echo "BLOCKED: direct push to a protected branch is not allowed from this workspace." >&2
  echo "Create a feature branch and open a pull request instead." >&2
  exit 2
fi

exit 0
