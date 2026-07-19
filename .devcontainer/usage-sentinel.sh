#!/usr/bin/env bash
# Optional tool: usage-sentinel (https://github.com/Sadotu/usage-sentinel).
#
# A local Node/TS service that reads the Claude/Codex CLI credential files
# (read-only) and exposes rolling-usage percentages over http://127.0.0.1:4317.
# Baked into the image at /opt/agent-devcontainer/usage-sentinel.sh and invoked
# from two places, both idempotent:
#   - setup-agents.sh (postCreate) — does the heavy clone+build the first time
#   - postStartCommand              — re-launches the service after a plain
#                                     container restart (postCreate does NOT
#                                     re-run on restart, only on create/rebuild)
#
# Optional + default-on: gated on INSTALL_USAGE_SENTINEL (set in the project's
# devcontainer.json containerEnv). Unset ⇒ on; set to 0 ⇒ skip entirely.
#
# Runtime notes:
#   - dist/ is gitignored upstream, so a fresh clone must be built once
#     (npm install pulls only devDeps — typescript etc.; there are zero runtime
#     deps). The checkout lives on a persisted named volume so rebuilds skip
#     the clone+build and stay headless (same philosophy as ~/.claude/oauth-env).
#   - Never exits nonzero on an expected/handled condition: it is wired as a
#     devcontainer lifecycle command, and a nonzero exit there is noisy.
set -uo pipefail

# --- gate ---------------------------------------------------------------------
if [ "${INSTALL_USAGE_SENTINEL:-1}" = "0" ]; then
  echo "==> usage-sentinel: disabled (INSTALL_USAGE_SENTINEL=0), skipping."
  exit 0
fi

BASE="$HOME/.local/share/usage-sentinel"
REPO_DIR="$BASE/repo"
LOG="$BASE/service.log"
URL="http://127.0.0.1:4317"
mkdir -p "$BASE"

# --- clone (once; refresh only when the checkout is missing) -------------------
# Public repo → no auth needed. --depth 1 on main is enough (dist is built here,
# not fetched). To pick up upstream changes, wipe the volume / delete "$REPO_DIR".
if [ ! -d "$REPO_DIR/.git" ]; then
  echo "==> usage-sentinel: cloning Sadotu/usage-sentinel"
  rm -rf "$REPO_DIR"
  if ! git clone --depth 1 https://github.com/Sadotu/usage-sentinel "$REPO_DIR" \
      >"$BASE/clone.log" 2>&1; then
    echo "WARNING: usage-sentinel clone failed — see $BASE/clone.log. Skipping."
    exit 0
  fi
fi

# --- build (once; dist/ is gitignored upstream so it never arrives via clone) --
if [ ! -f "$REPO_DIR/dist/index.js" ]; then
  echo "==> usage-sentinel: building (npm install + npm run build, first run only)"
  if ! ( cd "$REPO_DIR" && npm install && npm run build ) >"$BASE/build.log" 2>&1; then
    echo "WARNING: usage-sentinel build failed — see $BASE/build.log. Skipping."
    exit 0
  fi
fi
if [ ! -f "$REPO_DIR/dist/index.js" ]; then
  echo "WARNING: usage-sentinel: dist/index.js absent after build — see $BASE/build.log. Skipping."
  exit 0
fi

# --- start (only if nothing is already serving on 4317) -----------------------
# curl -sf returns nonzero when the port isn't listening; that's the signal to
# (re)launch. setsid detaches the service from this lifecycle process so it
# survives once setup/postStart returns.
if curl -sf "$URL/health" >/dev/null 2>&1; then
  echo "==> usage-sentinel: already running at $URL"
  exit 0
fi

echo "==> usage-sentinel: starting service at $URL (log: $LOG)"
( cd "$REPO_DIR" && setsid nohup node dist/index.js >"$LOG" 2>&1 & )

# Give it a moment, then report — but never fail the lifecycle on a slow start.
for _ in 1 2 3 4 5; do
  if curl -sf "$URL/health" >/dev/null 2>&1; then
    echo "    usage-sentinel: up at $URL"
    exit 0
  fi
  sleep 1
done
echo "    usage-sentinel: launched; not answering /health yet (see $LOG). Continuing."
exit 0
