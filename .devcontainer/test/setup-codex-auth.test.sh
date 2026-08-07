#!/usr/bin/env bash
# Exercises setup-agents.sh's Codex bootstrap block with a fake Bitwarden CLI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP="$ROOT/.devcontainer/setup-agents.sh"
LIB="$ROOT/.devcontainer/lib/bw-session.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

OLD_AUTH='{"tokens":{"refresh_token":"old-refresh","access_token":"old-access"}}'
NEW_AUTH='{"tokens":{"refresh_token":"new-refresh","access_token":"new-access"}}'
INVALID_AUTH='{"tokens":{"access_token":"no-refresh"}}'

mkdir -p "$TMP/bin"
cat >"$TMP/bin/bw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1 ${2:-}" in
  "get notes")
    [ "$3" = "codex-auth-token" ] || exit 9
    [ -r "$VAULT_NOTES_FILE" ] && cat "$VAULT_NOTES_FILE"
    ;;
  *)
    echo "UNEXPECTED bw call: $*" >&2
    exit 9
    ;;
esac
EOF
chmod +x "$TMP/bin/bw"
export PATH="$TMP/bin:$PATH"
export BW_SESSION='fake-session'

# Run exactly the production Codex setup block, bounded by its section markers.
run_setup() {
  local notes="$1"
  export HOME="$TMP/home"
  export VAULT_NOTES_FILE="$TMP/vault-notes"
  rm -rf "$HOME"
  mkdir -p "$HOME/.codex"
  printf '%s' "$OLD_AUTH" >"$HOME/.codex/auth.json"
  chmod 644 "$HOME/.codex/auth.json"
  rm -f "$VAULT_NOTES_FILE"
  [ "$notes" = __MISSING__ ] || printf '%s' "$notes" >"$VAULT_NOTES_FILE"

  set +e
  OUT="$({
    source "$LIB"
    sed -n '/^# --- Codex CLI auth/,/^# Lock the vault/p' "$SETUP" | sed '$d' | source /dev/stdin
  } 2>&1)"
  STATUS=$?
  set -e
}

assert_preserved() {
  [ "$(cat "$HOME/.codex/auth.json")" = "$OLD_AUTH" ] || fail "$1: existing auth changed"
  [ "$(stat -c '%a' "$HOME/.codex/auth.json")" = 644 ] || fail "$1: existing mode changed"
}

assert_no_residue() {
  if find "$HOME/.codex" -maxdepth 1 \( -name '.auth.json.tmp.*' -o -name '.auth.json.bak.*' \) | grep -q .; then
    fail "$1: staging or backup residue remains"
  fi
}

run_setup "$NEW_AUTH"
[ "$STATUS" -eq 0 ] || fail "valid notes: setup failed ($OUT)"
[ "$(cat "$HOME/.codex/auth.json")" = "$NEW_AUTH" ] || fail "valid notes: old auth not refreshed"
[ "$(stat -c '%a' "$HOME/.codex/auth.json")" = 600 ] || fail "valid notes: expected mode 600"
assert_no_residue "valid notes"

run_setup "$INVALID_AUTH"
[ "$STATUS" -eq 0 ] || fail "invalid notes: best-effort setup failed ($OUT)"
assert_preserved "invalid notes"
grep -qi "not valid Codex auth JSON" <<<"$OUT" || fail "invalid notes: missing clear warning ($OUT)"
assert_no_residue "invalid notes"

run_setup __MISSING__
[ "$STATUS" -eq 0 ] || fail "missing notes: best-effort setup failed ($OUT)"
assert_preserved "missing notes"
grep -qi "no .*notes" <<<"$OUT" || fail "missing notes: missing clear report ($OUT)"
assert_no_residue "missing notes"

echo "PASS: setup-codex-auth.test.sh"
