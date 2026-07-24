#!/usr/bin/env bash
# Shared Bitwarden-session plumbing, sourced by setup-agents.sh (postCreate)
# and codex-auth-sync.sh (dc codex-push / codex-pull). Sourceable library —
# defines functions and session-state globals only, no top-level side effects,
# no `set -e` of its own (the sourcing script owns shell options).
#
# Every consumer that needs the vault — the GitHub App key, the Claude token,
# the Codex auth, and the codex-push/pull commands — calls ensure_bw_session,
# so the unlock is DECOUPLED from any single consumer and happens at most once.

# Fatal-error helper: every bw failure path funnels here. Exits nonzero so
# `dc up` surfaces the postCreate failure instead of scrolling past it.
bw_fail() {
  echo "" >&2
  echo "ERROR: $1" >&2
  shift
  local line
  for line in "$@"; do echo "       $line" >&2; done
  echo "" >&2
  echo "       Fix the issue, then re-run setup WITHOUT a rebuild:" >&2
  echo "         ./.devcontainer/dc setup" >&2
  echo "       (Manual fallback — drop the credentials in yourself:" >&2
  echo "        see 'Repository access' in the agent-devcontainer README.)" >&2
  exit 1
}

# Idempotent Bitwarden unlock. Sets the global BW_SESSION (and marks
# bw_unlocked_by_us so a caller can re-lock). Previously the unlock lived
# inside setup-agents.sh's "App key missing" branch, so on a rebuild where that
# key was already in its persisted volume the vault was never unlocked and the
# Claude/Codex seeds silently no-op'd.
#
#   ensure_bw_session fatal       — unrecoverable failure aborts via bw_fail
#   ensure_bw_session besteffort  — failure just warns and returns 1
#
# Returns 0 with BW_SESSION set on success.
bw_unlocked_by_us=false
bw_session_announced=false
ensure_bw_session() {
  local mode="$1"
  if [ -n "${BW_SESSION:-}" ]; then
    if [ "$bw_session_announced" != true ]; then
      echo "    Reusing existing BW_SESSION."
      bw_session_announced=true
    fi
    return 0
  fi
  if ! command -v bw >/dev/null 2>&1; then
    [ "$mode" = fatal ] && bw_fail "Bitwarden CLI (bw) not found in the image — cannot fetch the GitHub App key."
    echo "    WARN: Bitwarden CLI (bw) not found — skipping best-effort seed." >&2
    return 1
  fi
  local bw_attempt=1 bw_log
  while :; do
    bw_log="$(mktemp)"
    if NO_COLOR=1 FORCE_COLOR=0 bw login --check >/dev/null 2>&1; then
      # Already logged in (login state persisted from a prior run in this
      # container) — just needs unlocking.
      echo "    Bitwarden already logged in — unlocking (interactive)..."
      NO_COLOR=1 FORCE_COLOR=0 bw unlock 2>&1 | tee "$bw_log" >&2 || true
    else
      # A successful `bw login` already unlocks the vault as part of
      # authenticating — no separate `bw unlock` needed.
      echo "    Logging into Bitwarden (interactive — one-time per container)..."
      NO_COLOR=1 FORCE_COLOR=0 bw login 2>&1 | tee "$bw_log" >&2 || true
    fi
    # Strip ANSI escapes before parsing. `|| true` guards the whole pipeline:
    # under `set -eo pipefail`, grep finding no match (the expected outcome on
    # a failed login) would otherwise kill the script here (see CLAUDE.md).
    BW_SESSION="$(sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$bw_log" \
      | grep -oE 'BW_SESSION="[^"]*"' | head -1 | cut -d'"' -f2 || true)"
    if [ -n "$BW_SESSION" ]; then
      rm -f "$bw_log"
      bw_unlocked_by_us=true
      bw_session_announced=true
      return 0
    fi
    # No session — classify the failure from bw's own output.
    if grep -qiE 'ENOTFOUND|ECONNREFUSED|ETIMEDOUT|EAI_AGAIN|network error|cannot connect|failed to fetch' "$bw_log"; then
      rm -f "$bw_log"
      [ "$mode" = fatal ] && bw_fail "Cannot reach Bitwarden — network problem (see output above)." \
        "Check the container's network / VPN / Bitwarden server status."
      echo "    WARN: cannot reach Bitwarden (network) — skipping best-effort seed." >&2
      return 1
    fi
    if grep -qiE 'incorrect|invalid master password' "$bw_log"; then
      rm -f "$bw_log"
      if [ "$bw_attempt" -ge 3 ]; then
        [ "$mode" = fatal ] && bw_fail "Bitwarden login/unlock failed after 3 attempts (wrong master password?)."
        echo "    WARN: Bitwarden unlock failed (wrong master password) — skipping best-effort seed." >&2
        return 1
      fi
      bw_attempt=$((bw_attempt + 1))
      echo "    Wrong credentials — retrying (attempt $bw_attempt/3)..."
      continue
    fi
    # Neither a session nor a recognizable error: most likely bw never got an
    # interactive terminal to prompt on (e.g. VS Code "Rebuild Container" runs
    # postCreate without stdin). Dump the log for diagnosis.
    echo "    DEBUG: could not find a session key in bw's output — raw log:"
    sed 's/^/    | /' "$bw_log"
    rm -f "$bw_log"
    [ "$mode" = fatal ] && bw_fail "Bitwarden login produced no session and no recognizable error." \
      "If this setup ran non-interactively (VS Code rebuild), run it from" \
      "a terminal instead — that's what 'dc setup' below is for."
    echo "    WARN: Bitwarden not available non-interactively — skipping best-effort seed." >&2
    return 1
  done
}

# Re-lock the vault only if THIS process unlocked it — a caller-provided
# BW_SESSION means they manage its lifecycle. Call this after every consumer
# that reuses the session has run; locking earlier invalidates the session.
bw_relock_if_ours() {
  if [ "${bw_unlocked_by_us:-false}" = true ]; then
    bw lock >/dev/null 2>&1 || true
  fi
}

# True when the given string is a real Codex auth.json — carries a
# .tokens.refresh_token (so it self-renews). The single validity check applied
# in BOTH directions: setup-agents.sh's seed on read, and codex-push /
# codex-pull. Takes the JSON as its first argument.
codex_auth_is_valid() {
  printf '%s' "$1" | jq -e '.tokens.refresh_token' >/dev/null 2>&1
}
