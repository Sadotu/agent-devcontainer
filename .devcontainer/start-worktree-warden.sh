#!/usr/bin/env bash
# postStartCommand for the shared agent devcontainer image. Baked into the
# image at /opt/agent-devcontainer/start-worktree-warden.sh and wired as
# devcontainer.json's postStartCommand, so it runs on EVERY container start
# (including a plain restart, not just first create/rebuild) — it must be
# idempotent and safe to re-run with no duplicate side effects.
#
# Autostarts exactly one instance of `worktree-warden` (npm:
# @nickysagan/worktree-warden) per repository, backgrounded in its own tmux
# session. `worktree-warden` with no arguments runs as a FOREGROUND watcher
# daemon (polls every 60s) — it never backgrounds itself, so whoever starts
# it must background it (hence tmux). It also maintains its own atomic,
# self-healing single-instance PID lock at
# <git-common-dir>/worktree-warden/warden.pid (stale PIDs reclaimed
# automatically), so the `tmux has-session` check below is the FIRST
# duplicate-prevention layer, not the only one.
#
# Deliberately no `set -e`: every unmet precondition here (setup not done
# yet, credentials not seeded yet, the CLI not installed yet) is an expected,
# not-ready-yet condition, not an internal error — each such branch prints
# one short line and exits 0 so postStartCommand never fails the container
# start. `set -u` is safe (every var we read is either given a default or
# assigned before use) and pipefail costs nothing since nothing here pipes.
set -uo pipefail

# --- 1. Resolve WORKSPACE the same way setup-agents.sh does ------------------
# Respect an already-exported WORKSPACE (tests, or any caller that already
# knows it) so this stays testable without requiring PROJECT_NAME too.
if [ -z "${WORKSPACE:-}" ]; then
  WORKSPACE="/workspaces/${PROJECT_NAME:-}"
fi

# postStartCommand is a separate non-interactive process — it does NOT source
# .bashrc, so the `PATH="$HOME/.npm-global/bin:$PATH"` export setup-agents.sh
# appends there never reaches it. Without this, `command -v worktree-warden`
# below would normally resolve the Dockerfile-baked root-owned fallback
# instead of whatever `npm install -g @nickysagan/worktree-warden@latest`
# actually installed — same shadowing setup-agents.sh does for itself
# in-script, needed here for the same reason.
export PATH="$HOME/.npm-global/bin:$PATH"

# Resolve this script's own dir so its sourceable libs work both baked into
# the image (/opt/agent-devcontainer) and from a repo checkout (tests) —
# same _SETUP_DIR-style pattern setup-agents.sh uses. TOOLDIR is overridable
# (tests point it at a stub refresh-skills.sh) but defaults to right here,
# since refresh-skills.sh is baked alongside this script.
_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLDIR="${TOOLDIR:-$_SETUP_DIR}"

# --- 2. Setup must have completed at least once ------------------------------
# shellcheck source=lib/setup-marker.sh
source "$_SETUP_DIR/lib/setup-marker.sh"
if [ ! -r "$(setup_marker_path)" ]; then
  echo "worktree-warden: setup has not completed yet (no readiness marker) — skipping autostart."
  exit 0
fi

GITHUB_APP_DIR="$HOME/.config/github-app"

# Steps 3-7 (the warden autostart itself) are wrapped in a function that
# `return`s on each not-ready condition instead of exiting the whole script —
# unlike the setup-marker check above, none of these conditions (App creds,
# the warden CLI, tmux) should also block step 8's skill refresh below: the
# core resolve step needs neither GitHub App creds nor the warden CLI, only
# its own bump-PR path (opening a PR for a moved skill pin) needs creds, and
# that path already degrades gracefully on its own if they're absent.
start_worktree_warden() {
  # --- 3. GitHub App credentials must be present ------------------------------
  if [ ! -r "$GITHUB_APP_DIR/private-key.pem" ] || [ ! -r "$GITHUB_APP_DIR/app-id" ]; then
    echo "worktree-warden: GitHub App credentials not present yet — skipping autostart."
    return 0
  fi

  # --- 4. worktree-warden CLI must be installed -------------------------------
  if ! command -v worktree-warden >/dev/null 2>&1; then
    echo "worktree-warden: CLI not found on PATH — skipping autostart."
    return 0
  fi

  # --- 5. tmux must be available (defensive; always baked into this image) ---
  if ! command -v tmux >/dev/null 2>&1; then
    echo "worktree-warden: tmux not found on PATH — skipping autostart."
    return 0
  fi

  # --- 6. Primary duplicate-prevention layer: an existing tmux session -------
  if tmux has-session -t worktree-warden 2>/dev/null; then
    echo "worktree-warden: tmux session 'worktree-warden' already running — skipping autostart."
    return 0
  fi

  # --- 7. Start it, backgrounded in its own tmux session ----------------------
  # worktree-warden only ever appends its results to warden.log (fs.appendFile,
  # see its src/log.js) — it never writes to stdout/stderr, so the tmux pane
  # would show nothing at all on its own. Issue #63 requires failures to
  # "print immediately in the Warden tmux output", so the pane runs a small
  # wrapper that tails that same log file alongside the daemon: `worktree-warden`
  # itself stays the pane's foreground process (so the tmux session's lifetime
  # still tracks the daemon's, matching the dedup check above), with `tail -F`
  # backgrounded inside the same pane purely to mirror new log lines into it.
  #
  # worktree-warden's own default for WARDEN_CLEANUP_SCRIPT points at the
  # github-issue skill's old cleanup-merged.sh, which moved (and was renamed)
  # to the github-pr-cleanup skill's cleanup.sh — override it explicitly so
  # the daemon finds the script that's actually installed.
  export WARDEN_CLEANUP_SCRIPT="$WORKSPACE/.agents/skills/github-pr-cleanup/scripts/cleanup.sh"
  local git_common_dir warden_log
  git_common_dir="$(git -C "$WORKSPACE" rev-parse --git-common-dir 2>/dev/null)"
  case "$git_common_dir" in
    /*) ;;
    *) git_common_dir="$WORKSPACE/$git_common_dir" ;;
  esac
  warden_log="$git_common_dir/worktree-warden/warden.log"
  mkdir -p "$(dirname "$warden_log")"
  touch "$warden_log"

  if tmux new-session -d -s worktree-warden -c "$WORKSPACE" -- \
      bash -c 'tail -n0 -F "$1" & tail_pid=$!; worktree-warden; status=$?; kill "$tail_pid" 2>/dev/null; exit "$status"' \
      _ "$warden_log"; then
    # `tmux new-session -d` only proves the session was created, not that the
    # pane's command survived past its own startup — a worktree-warden crash
    # immediately after launch (e.g. before it ever writes to warden.log or
    # state.json) tears the session down again just as fast, and without this
    # recheck that already-dead session would still be reported as "started".
    # Not a full health check (still racy for a crash slightly past this grace
    # window), just closing the "reported success while already dead" gap.
    sleep 1
    if tmux has-session -t worktree-warden 2>/dev/null; then
      echo "worktree-warden: started in tmux session 'worktree-warden'."
    else
      echo "worktree-warden: tmux session exited immediately after starting — worktree-warden crashed on startup. Check the container's postStartCommand output and $warden_log." >&2
    fi
  else
    local tmux_status=$?
    echo "worktree-warden: failed to start tmux session (tmux exit $tmux_status) — worktree-warden is NOT running." >&2
  fi
}
start_worktree_warden

# --- 8. Re-resolve self-authored skills (issue #92) ---------------------------
# Runs after the warden autostart above so a slow/failed refresh never delays
# the daemon — and independent of whether the warden itself started, since
# the core resolve step needs neither GitHub App creds nor the warden CLI.
# Same script setup-agents.sh calls at postCreate — see there and
# refresh-skills.sh itself for its own not-ready/timeout contract, which
# already guarantees this never fails container start.
WORKSPACE="$WORKSPACE" TOOLDIR="$TOOLDIR" PROJECT_NAME="${PROJECT_NAME:-}" \
  GH_OWNER="${GH_OWNER:-}" GITHUB_APP_DIR="$GITHUB_APP_DIR" \
  "$TOOLDIR/refresh-skills.sh"
exit 0
