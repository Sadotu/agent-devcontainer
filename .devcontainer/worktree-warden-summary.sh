#!/usr/bin/env bash
# Prints a concise summary of unresolved worktree-warden attention items.
# Sourceable library — no top-level `set -e`/`set -o pipefail` of its own
# (sourced from .bashrc and from start-work.sh, both of which must never
# abort just because this script errors), same contract as
# lib/setup-marker.sh and lib/bw-session.sh.
#
# worktree-warden (npm: @nickysagan/worktree-warden) is a daemon that watches
# agent PRs and, when cleanup fails or needs attention, writes a JSON record
# to <git-common-dir>/worktree-warden/state.json:
#
#   {
#     "<branch-name>": {
#       "branch": "agent/45-foo", "pr": 123, "issue": 45,
#       "status": "blocked", "reason": "dirty-worktree",
#       "diagnostic": "...", "updatedAt": "..."
#     },
#     "__runOnce__": {
#       "branch": "__runOnce__", "pr": null, "issue": null,
#       "status": "<daemon-error-status>", "reason": "...",
#       "diagnostic": "...", "updatedAt": "..."
#     }
#   }
#
# status: "pending" means in-flight and is skipped. Anything else (blocked,
# retry, waiting, or a daemon-error status under the reserved __runOnce__
# key) is an unresolved attention item this prints one line for, e.g.:
#   Worktree Warden: PR #123 / issue #45 failed — blocked: dirty-worktree

worktree_warden_summary() {
  local dir common_dir state_file
  dir="${1:-$PWD}"

  # --git-common-dir can return a path relative to $dir (e.g. plain ".git")
  # rather than absolute — join it ourselves. Same idiom as the
  # worktree-warden package's own resolveGitCommonDir() in src/repo.js. If
  # this isn't a git repo at all, git exits nonzero: return silently, no
  # error output.
  common_dir="$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null)" || return 0
  case "$common_dir" in
    /*) ;;
    *) common_dir="$dir/$common_dir" ;;
  esac

  state_file="$common_dir/worktree-warden/state.json"
  [[ -r "$state_file" ]] || return 0

  # Scoped to a subshell with its own stderr suppression: jq failures
  # (missing jq, invalid JSON, anything else) must never print to the
  # caller's shell or propagate a nonzero status past this function. The
  # trailing `|| true` matters even though this function ends with an
  # explicit `return 0`: this function is sourced into callers that may
  # themselves run under `set -e` (e.g. start-work.sh), and a plain command
  # (this subshell) exiting nonzero would trip THEIR -e and abort before
  # that `return 0` is ever reached.
  (
    jq -e '.' "$state_file" >/dev/null 2>&1 || exit 1
    jq -r '
      to_entries[]
      | select(.value.status != "pending")
      | if .key == "__runOnce__" then
          "Worktree Warden: daemon error — \(.value.status): \(.value.reason // "unknown")"
        else
          "Worktree Warden: PR #\(.value.pr // "?") / issue #\(.value.issue // "?") failed — \(.value.status): \(.value.reason // "unknown")"
        end
    ' "$state_file"
  ) 2>/dev/null || true

  return 0
}
