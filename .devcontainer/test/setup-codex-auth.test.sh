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
EMPTY_REFRESH='{"tokens":{"refresh_token":""}}'
NULL_REFRESH='{"tokens":{"refresh_token":null}}'
NONSTRING_REFRESH='{"tokens":{"refresh_token":123}}'

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

for invalid_case in "$EMPTY_REFRESH" "$NULL_REFRESH" "$NONSTRING_REFRESH"; do
  run_setup "$invalid_case"
  [ "$STATUS" -eq 0 ] || fail "strict invalid notes: best-effort setup failed ($OUT)"
  assert_preserved "strict invalid notes"
  grep -qi "not valid Codex auth JSON" <<<"$OUT" || fail "strict invalid notes: missing clear warning ($OUT)"
  assert_no_residue "strict invalid notes"
done

run_setup __MISSING__
[ "$STATUS" -eq 0 ] || fail "missing notes: best-effort setup failed ($OUT)"
assert_preserved "missing notes"
grep -qi "no .*notes" <<<"$OUT" || fail "missing notes: missing clear report ($OUT)"
assert_no_residue "missing notes"

# --- replacement remains atomic: live destination exists until rename -------
ATOMIC_HOME="$TMP/atomic-home"
ATOMIC_AUTH="$ATOMIC_HOME/.codex/auth.json"
mkdir -p "$ATOMIC_HOME/.codex" "$TMP/atomic-bin"
printf '%s' "$OLD_AUTH" >"$ATOMIC_AUTH"
cat >"$TMP/atomic-bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source_path="${@: -2:1}"
destination="${@: -1}"
if [[ "$source_path" == */.auth.json.tmp.* && "$destination" == */auth.json ]] && [ ! -e "$destination" ]; then
  echo "destination absent before atomic replacement" >&2
  exit 97
fi
exec /bin/mv "$@"
EOF
chmod +x "$TMP/atomic-bin/mv"
set +e
ATOMIC_OUT="$(PATH="$TMP/atomic-bin:$PATH" bash -c '
  source "$1"
  install_codex_auth_atomically "$2" "$3"
' _ "$LIB" "$NEW_AUTH" "$ATOMIC_AUTH" 2>&1)"
ATOMIC_STATUS=$?
set -e
[ "$ATOMIC_STATUS" -eq 0 ] || fail "atomic replacement: live destination disappeared ($ATOMIC_OUT)"
[ "$(cat "$ATOMIC_AUTH")" = "$NEW_AUTH" ] || fail "atomic replacement: new auth not installed"

# --- failed rollback retains the only old-auth copy and reports its path -----
ROLLBACK_HOME="$TMP/rollback-home"
ROLLBACK_AUTH="$ROLLBACK_HOME/.codex/auth.json"
ROLLBACK_LOG="$TMP/rollback-mv.log"
ROLLBACK_MODE_LOG="$TMP/rollback-mode.log"
mkdir -p "$ROLLBACK_HOME/.codex" "$TMP/fail-bin"
printf '%s' "$OLD_AUTH" >"$ROLLBACK_AUTH"
chmod 644 "$ROLLBACK_AUTH"
cat >"$TMP/fail-bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source_path="${@: -2:1}"
destination="${@: -1}"
if [[ "$source_path" == */.auth.json.bak.* && "$destination" == */auth.json ]]; then
  printf '%s\n' "$source_path" >"$ROLLBACK_LOG"
  /usr/bin/stat -c '%a' "$source_path" >"$ROLLBACK_MODE_LOG"
  exit 1
fi
exec /bin/mv "$@"
EOF
cat >"$TMP/fail-bin/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target="${@: -1}"
if [[ "$target" == */auth.json ]]; then
  printf '644\n'
  exit 0
fi
exec /usr/bin/stat "$@"
EOF
chmod +x "$TMP/fail-bin/mv" "$TMP/fail-bin/stat"
export ROLLBACK_LOG ROLLBACK_MODE_LOG
set +e
ROLLBACK_OUT="$(PATH="$TMP/fail-bin:$PATH" bash -c '
  source "$1"
  install_codex_auth_atomically "$2" "$3"
' _ "$LIB" "$NEW_AUTH" "$ROLLBACK_AUTH" 2>&1)"
ROLLBACK_STATUS=$?
set -e
[ "$ROLLBACK_STATUS" -ne 0 ] || fail "rollback failure: helper unexpectedly succeeded"
[ -s "$ROLLBACK_LOG" ] || fail "rollback failure: restore path was not exercised"
retained_backup="$(cat "$ROLLBACK_LOG")"
[ -f "$retained_backup" ] || fail "rollback failure: sole old-auth backup was deleted"
[ "$(cat "$retained_backup")" = "$OLD_AUTH" ] || fail "rollback failure: retained backup changed"
[ "$(cat "$ROLLBACK_MODE_LOG")" = 600 ] || fail "rollback failure: credential backup was not mode 600"
grep -Fq "$retained_backup" <<<"$ROLLBACK_OUT" \
  || fail "rollback failure: retained backup location not reported ($ROLLBACK_OUT)"

echo "PASS: setup-codex-auth.test.sh"
