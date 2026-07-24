#!/usr/bin/env bash
# Codex-auth sync between this container's ~/.codex/auth.json and the Bitwarden
# 'codex-auth-token' item's Notes. Baked into the image at
# /opt/agent-devcontainer/codex-auth-sync.sh and invoked, inside the running
# container, by the host-side `dc codex-push` / `dc codex-pull` commands
# (`dc` is host-side and can reach neither `bw` nor the ~/.codex volume, so the
# work runs here — same split as `dc setup`).
#
#   codex-auth-sync.sh push          upload ~/.codex/auth.json to the vault
#   codex-auth-sync.sh pull --force  overwrite ~/.codex/auth.json from the vault
#
# The Bitwarden unlock and the .tokens.refresh_token validity check come from
# the same lib setup-agents.sh uses, so a fresh/stale token is validated
# identically in both directions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/bw-session.sh
source "$SCRIPT_DIR/lib/bw-session.sh"

CODEX_AUTH="${CODEX_AUTH:-$HOME/.codex/auth.json}"
# Same well-known item (and override) setup-agents.sh seeds from.
CODEX_ITEM="${BW_CODEX_AUTH_ITEM_ID:-codex-auth-token}"

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat >&2 <<EOF
usage: codex-auth-sync.sh push
       codex-auth-sync.sh pull --force

  push          upload this container's $CODEX_AUTH to the Bitwarden
                '$CODEX_ITEM' item's Notes (validated first)
  pull --force  overwrite $CODEX_AUTH from the vault. --force is required —
                it clobbers a possibly live, already-refreshed local token;
                Codex refresh tokens rotate on use, so a stale vault copy over
                a fresher local one invalidates the working session.
EOF
  exit 2
}

do_push() {
  [ -r "$CODEX_AUTH" ] || die "No readable $CODEX_AUTH to push — nothing to upload."
  local local_json
  local_json="$(cat "$CODEX_AUTH")"
  codex_auth_is_valid "$local_json" \
    || die "$CODEX_AUTH is not valid Codex auth JSON (.tokens.refresh_token missing) — refusing to push."

  ensure_bw_session fatal

  local item_json id updated
  item_json="$(bw get item "$CODEX_ITEM" --session "$BW_SESSION" 2>/dev/null || true)"
  [ -n "$item_json" ] || die "Bitwarden item '$CODEX_ITEM' not found — create it (Notes hold the auth.json)."
  id="$(printf '%s' "$item_json" | jq -r '.id')"
  updated="$(printf '%s' "$item_json" | jq --arg n "$local_json" '.notes=$n')"
  printf '%s' "$updated" | bw encode | bw edit item "$id" --session "$BW_SESSION" >/dev/null \
    || die "Failed to write Notes to Bitwarden item '$CODEX_ITEM'."
  echo "Pushed $CODEX_AUTH to Bitwarden item '$CODEX_ITEM'."

  bw_relock_if_ours
}

do_pull() {
  ensure_bw_session fatal

  local notes
  notes="$(bw get notes "$CODEX_ITEM" --session "$BW_SESSION" 2>/dev/null || true)"
  [ -n "$notes" ] || die "Bitwarden item '$CODEX_ITEM' has no Notes to pull."
  codex_auth_is_valid "$notes" \
    || die "'$CODEX_ITEM' Notes are not valid Codex auth JSON — refusing to overwrite $CODEX_AUTH."

  mkdir -p "$(dirname "$CODEX_AUTH")"
  printf '%s\n' "$notes" >"$CODEX_AUTH"
  chmod 600 "$CODEX_AUTH"
  echo "Pulled Bitwarden item '$CODEX_ITEM' into $CODEX_AUTH (overwritten)."

  bw_relock_if_ours
}

mode="${1:-}"
shift || true
case "$mode" in
  push)
    [ "$#" -eq 0 ] || usage
    do_push
    ;;
  pull)
    [ "${1:-}" = "--force" ] || usage
    do_pull
    ;;
  *)
    usage
    ;;
esac
