#!/usr/bin/env bash
# Re-resolves declared skills (dotagents) to their source's latest commit.
# Baked into the image at /opt/agent-devcontainer/refresh-skills.sh and
# called from BOTH setup-agents.sh (postCreate) and start-worktree-warden.sh
# (postStart) — see issue #92: postCreate-only re-resolution left a container
# serving stale skills for its whole lifetime between rebuilds.
#
# Contract mirrors start-worktree-warden.sh: no `set -e`, every not-ready
# condition prints one line and exits 0 — this must never fail whichever
# caller invoked it (postCreate setup, or postStart container start).
set -uo pipefail

if [ -z "${WORKSPACE:-}" ]; then
  WORKSPACE="/workspaces/${PROJECT_NAME:-}"
fi
PROJECT_NAME="${PROJECT_NAME:-}"
GH_OWNER="${GH_OWNER:-}"
GITHUB_APP_DIR="${GITHUB_APP_DIR:-$HOME/.config/github-app}"

# Resolve this script's own dir so TOOLDIR defaults correctly both baked into
# the image (/opt/agent-devcontainer) and from a repo checkout (tests), same
# _SETUP_DIR-style pattern setup-agents.sh/start-worktree-warden.sh use. An
# explicit TOOLDIR (as setup-agents.sh always passes) wins.
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLDIR="${TOOLDIR:-$_SCRIPT_DIR}"

# postStart is a separate non-interactive process that never sources
# .bashrc, so the npm-global PATH prepend setup-agents.sh appends there never
# reaches it here — same shadowing fix start-worktree-warden.sh applies.
export PATH="$HOME/.npm-global/bin:$PATH"

if ! git -C "$WORKSPACE" rev-parse --git-dir >/dev/null 2>&1; then
  echo "refresh-skills: '$WORKSPACE' is not a git repository — skipping."
  exit 0
fi

if [ ! -x "$TOOLDIR/dotagents-install.sh" ]; then
  echo "refresh-skills: $TOOLDIR/dotagents-install.sh not found — skipping."
  exit 0
fi

# Reuse a single open bump PR across every start instead of opening one per
# run (#92 Scope) — a per-run branch would pile up unmergeable PRs once the
# trigger is every container start rather than create-only/rare (#79).
BUMP_BRANCH="agent/agents-lock-upgrade"
git_common_dir="$(git -C "$WORKSPACE" rev-parse --git-common-dir 2>/dev/null)"
case "$git_common_dir" in
  /*) ;;
  *) git_common_dir="$WORKSPACE/$git_common_dir" ;;
esac
# Keep the lock in this repository's common Git directory so every linked
# worktree shares it, while unrelated repositories never block each other.
# It covers fetch, resolution, worktree lifecycle, and publication: postCreate
# and postStart may overlap, and all of those steps share refs or remote state.
BUMP_FLOCK="$git_common_dir/agents-lock-bump.flock"

install_dotagents() {
  local WORKSPACE="$1"
  timeout "$timeout_secs" "$TOOLDIR/dotagents-install.sh" "$WORKSPACE" "$TOOLDIR"
}

resolve_and_bump_agents_lock() {
  local bump_wt bump_pr_url="" existing_pr="" status
  if ! git -C "$WORKSPACE" fetch -q origin main >/tmp/agents-lock-bump.log 2>&1; then
    echo "WARNING: fetching origin/main failed during agents.lock refresh — see /tmp/agents-lock-bump.log."
    return 0
  fi

  bump_wt="$(mktemp -d)"
  rmdir "$bump_wt"
  git -C "$WORKSPACE" worktree prune 2>/dev/null || true
  if ! git -C "$WORKSPACE" worktree add -q --detach "$bump_wt" origin/main \
      >>/tmp/agents-lock-bump.log 2>&1; then
    echo "WARNING: agents.lock refresh failed — see /tmp/agents-lock-bump.log."
    return 0
  fi

  if install_dotagents "$bump_wt" 2>&1 | sed 's/^/    /'; then
    if git -C "$bump_wt" diff --quiet -- agents.lock; then
      git -C "$WORKSPACE" worktree remove "$bump_wt" --force 2>/dev/null || rm -rf "$bump_wt"
      return 0
    fi
  else
    status=$?
    git -C "$WORKSPACE" worktree remove "$bump_wt" --force 2>/dev/null || rm -rf "$bump_wt"
    if [ "$status" -eq 124 ]; then
      echo "WARNING: dotagents install timed out after ${timeout_secs}s — self-authored skills unavailable this run."
    else
      echo "WARNING: dotagents install failed — self-authored skills unavailable this run."
    fi
    return 0
  fi

  # Commit the detached resolution and publish it directly to the one fixed
  # remote branch. No local bump branch exists, so interrupted old worktrees
  # cannot pin that branch or influence the generated lock.
  if git -C "$bump_wt" add agents.lock && \
     git -C "$bump_wt" -c user.name="agent-devcontainer setup" \
       -c user.email="agent-devcontainer-setup@users.noreply.github.com" \
       commit -qm "chore: bump agents.lock skill pins (auto, dc up)" && \
     git -C "$bump_wt" push -qf origin "HEAD:refs/heads/$BUMP_BRANCH" >>/tmp/agents-lock-bump.log 2>&1; then
    existing_pr="$(GH_TOKEN="$("$TOOLDIR/gh-app-token.sh")" /usr/bin/gh pr list \
      --repo "$GH_OWNER/$PROJECT_NAME" --head "$BUMP_BRANCH" --state open \
      --json url --jq '.[0].url' 2>>/tmp/agents-lock-bump.log)" || existing_pr=""
    if [ -n "$existing_pr" ]; then
      bump_pr_url="$existing_pr"
    else
      bump_pr_url="$(GH_TOKEN="$("$TOOLDIR/gh-app-token.sh")" /usr/bin/gh pr create \
        --repo "$GH_OWNER/$PROJECT_NAME" --base main --head "$BUMP_BRANCH" \
        --title "chore: bump agents.lock skill pins" \
        --body "Automated \`agents.lock\` pin bump — skills re-resolved to their source's latest commit. Review the diff before merging." \
        2>>/tmp/agents-lock-bump.log)" || bump_pr_url=""
    fi
  fi
  git -C "$WORKSPACE" worktree remove "$bump_wt" --force 2>/dev/null || rm -rf "$bump_wt"
  if [ -n "$bump_pr_url" ]; then
    echo "WARNING: agents.lock changed (skills re-resolved) — see $bump_pr_url"
  else
    echo "WARNING: agents.lock changed but the auto-PR failed — see /tmp/agents-lock-bump.log."
  fi
}

refresh_agents_lock() {
  (
    flock -w 300 200 || {
      echo "WARNING: a concurrent refresh held the agents.lock refresh lock too long — see /tmp/agents-lock-bump.log."
      exit 0
    }
    resolve_and_bump_agents_lock
  ) 200>"$BUMP_FLOCK"
}

echo "==> Self-authored skills (dotagents)"
# Bounded so a hung download can never wedge container start (postStart) or
# postCreate. REFRESH_SKILLS_TIMEOUT overrides the 120s default for tests.
timeout_secs="${REFRESH_SKILLS_TIMEOUT:-120}"
refresh_agents_lock
exit 0
