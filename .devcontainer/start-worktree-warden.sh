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

# Resolve this script's own dir so its sourceable libs work both baked into
# the image (/opt/agent-devcontainer) and from a repo checkout (tests) —
# same _SETUP_DIR-style pattern setup-agents.sh uses.
_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 2. Setup must have completed at least once ------------------------------
# shellcheck source=lib/setup-marker.sh
source "$_SETUP_DIR/lib/setup-marker.sh"
if [ ! -r "$(setup_marker_path)" ]; then
  echo "worktree-warden: setup has not completed yet (no readiness marker) — skipping autostart."
  exit 0
fi

# --- 3. GitHub App credentials must be present --------------------------------
GITHUB_APP_DIR="$HOME/.config/github-app"
if [ ! -r "$GITHUB_APP_DIR/private-key.pem" ] || [ ! -r "$GITHUB_APP_DIR/app-id" ]; then
  echo "worktree-warden: GitHub App credentials not present yet — skipping autostart."
  exit 0
fi

# --- 4. worktree-warden CLI must be installed ---------------------------------
if ! command -v worktree-warden >/dev/null 2>&1; then
  echo "worktree-warden: CLI not found on PATH — skipping autostart."
  exit 0
fi

# --- 5. tmux must be available (defensive; always baked into this image) -----
if ! command -v tmux >/dev/null 2>&1; then
  echo "worktree-warden: tmux not found on PATH — skipping autostart."
  exit 0
fi

# --- 6. Primary duplicate-prevention layer: an existing tmux session ---------
if tmux has-session -t worktree-warden 2>/dev/null; then
  echo "worktree-warden: tmux session 'worktree-warden' already running — skipping autostart."
  exit 0
fi

# --- 7. Start it, backgrounded in its own tmux session ------------------------
tmux new-session -d -s worktree-warden -c "$WORKSPACE" -- worktree-warden
echo "worktree-warden: started in tmux session 'worktree-warden'."
exit 0
