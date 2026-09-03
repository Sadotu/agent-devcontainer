#!/usr/bin/env bash
# Claude-auth sync between this container's ~/.claude/oauth-env and the
# Bitwarden 'claude-code-oauth-token' item's Notes. Baked into the image at
# /opt/agent-devcontainer/claude-auth-sync.sh and invoked, inside the running
# container, by the host-side `dc claude-push` / `dc claude-pull` commands
# (`dc` is host-side and can reach neither `bw` nor the ~/.claude volume, so
# the work runs here — same split as `dc setup` and codex-auth-sync.sh).
#
#   claude-auth-sync.sh push   upload ~/.claude/oauth-env's token to the vault
#   claude-auth-sync.sh pull   overwrite ~/.claude/oauth-env from the vault
#
# Unlike codex-auth-sync.sh's `pull --force`, pull here takes no flag: Codex
# refresh tokens rotate on use, so a stale vault copy over a fresher local one
# can kill a live session — Claude's token does not rotate in-container, so
# that guard would be cargo-culted ceremony. There is also no host-side
# handoff: `dc claude-push`/`claude-pull` never touch the host's ~/.claude —
# that's a separate interactive login this sync must not clobber — so this
# script's own stdout/stderr just passes straight through.
#
# The Bitwarden unlock and the token-validity check come from the same lib
# setup-agents.sh uses, so a fresh/stale token is validated identically in
# both directions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/bw-session.sh
source "$SCRIPT_DIR/lib/bw-session.sh"

CLAUDE_OAUTH_ENV="${CLAUDE_OAUTH_ENV:-$HOME/.claude/oauth-env}"
# Same well-known item (and override) setup-agents.sh seeds from.
CLAUDE_ITEM="${BW_CLAUDE_TOKEN_ITEM_ID:-claude-code-oauth-token}"
die() { echo "ERROR: $*" >&2; exit 1; }

cleanup() {
  bw_relock_if_ours
}
trap cleanup EXIT

usage() {
  cat >&2 <<EOF
usage: claude-auth-sync.sh push
       claude-auth-sync.sh pull

  push  upload this container's $CLAUDE_OAUTH_ENV token to the Bitwarden
        '$CLAUDE_ITEM' item's Notes (validated first)
  pull  overwrite $CLAUDE_OAUTH_ENV from the vault (validated first). No
        --force: the Claude token does not rotate in-container, so there is
        no live-refresh to protect against (contrast codex-auth-sync.sh).
EOF
  exit 2
}

# Extract the token value from an `export CLAUDE_CODE_OAUTH_TOKEN=...` line,
# undoing the shell quoting printf %q applied when it was written.
extract_token() {
  local line
  line="$(grep '^export CLAUDE_CODE_OAUTH_TOKEN=' "$1" 2>/dev/null | tail -1)" || return 1
  [ -n "$line" ] || return 1
  eval "${line#export }"
  printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN"
}

do_push() {
  local local_token
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    local_token="$CLAUDE_CODE_OAUTH_TOKEN"
  elif [ -r "$CLAUDE_OAUTH_ENV" ]; then
    local_token="$(extract_token "$CLAUDE_OAUTH_ENV" || true)"
  else
    die "No CLAUDE_CODE_OAUTH_TOKEN and no readable $CLAUDE_OAUTH_ENV — nothing to upload."
  fi
  claude_oauth_token_is_valid "$local_token" \
    || die "No valid Claude OAuth token found (expected an 'sk-ant-oat' token, no whitespace) — refusing to push."

  ensure_bw_session fatal

  local item_json id updated
  item_json="$(bw get item "$CLAUDE_ITEM" --session "$BW_SESSION" 2>/dev/null || true)"
  [ -n "$item_json" ] || die "Bitwarden item '$CLAUDE_ITEM' not found — create it (Notes hold the token)."
  id="$(printf '%s' "$item_json" | jq -r '.id')"
  updated="$(printf '%s' "$item_json" | jq --arg n "$local_token" '.notes=$n')"
  printf '%s' "$updated" | bw encode | bw edit item "$id" --session "$BW_SESSION" >/dev/null \
    || die "Failed to write Notes to Bitwarden item '$CLAUDE_ITEM'."
  echo "Pushed $CLAUDE_OAUTH_ENV's token to Bitwarden item '$CLAUDE_ITEM'."
}

do_pull() {
  ensure_bw_session fatal

  local notes
  notes="$(bw get notes "$CLAUDE_ITEM" --session "$BW_SESSION" 2>/dev/null | tr -d '\r\n' || true)"
  [ -n "$notes" ] || die "Bitwarden item '$CLAUDE_ITEM' has no Notes to pull."
  claude_oauth_token_is_valid "$notes" \
    || die "'$CLAUDE_ITEM' Notes are not a valid Claude OAuth token — refusing to overwrite $CLAUDE_OAUTH_ENV."

  install_claude_oauth_env_atomically "$notes" "$CLAUDE_OAUTH_ENV" \
    || die "Failed to install pulled Claude OAuth token; previous oauth-env restored when possible."

  # Interactive Claude's first-run wizard still demands a login choice even
  # with the token set — seed the onboarding flag so a pulled token also
  # skips it (same guard setup-agents.sh applies on its own seed path).
  if [ ! -s "$HOME/.claude.json" ]; then
    printf '{"hasCompletedOnboarding": true}\n' > "$HOME/.claude.json"
  fi

  echo "Pulled Bitwarden item '$CLAUDE_ITEM' into $CLAUDE_OAUTH_ENV (overwritten)."
}

mode="${1:-}"
shift || true
case "$mode" in
  push)
    [ "$#" -eq 0 ] || usage
    do_push
    ;;
  pull)
    [ "$#" -eq 0 ] || usage
    do_pull
    ;;
  *)
    usage
    ;;
esac
