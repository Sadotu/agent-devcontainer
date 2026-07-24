#!/usr/bin/env bash
# Drives codex-auth-sync.sh push/pull against a fake `bw` vault. The
# interactive unlock is bypassed by pre-setting BW_SESSION (a caller-provided
# session, which ensure_bw_session reuses verbatim) — so these tests cover the
# push/pull logic, the .tokens.refresh_token validity gate applied in both
# directions, and the --force guard, without the TTY login path.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SYNC="$ROOT/.devcontainer/codex-auth-sync.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

VALID_AUTH='{"tokens":{"refresh_token":"rt-abc","access_token":"at-xyz"}}'
OTHER_VALID='{"tokens":{"refresh_token":"rt-NEW","access_token":"at-NEW"}}'
INVALID_AUTH='{"tokens":{"access_token":"at-only"}}'

# --- Fake bw: a single-item vault whose Notes live in $VAULT_NOTES_FILE ------
mkdir -p "$TMP/bin"
cat >"$TMP/bin/bw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1 ${2:-}" in
  "get item")
    [ "$3" = "$EXPECT_ITEM" ] || exit 1
    notes="$(cat "$VAULT_NOTES_FILE" 2>/dev/null || true)"
    jq -n --arg id 'item-id-123' --arg n "$notes" '{id:$id,name:"codex-auth-token",notes:$n}'
    ;;
  "get notes")
    [ "$3" = "$EXPECT_ITEM" ] || exit 1
    cat "$VAULT_NOTES_FILE" 2>/dev/null || true
    ;;
  "encode ")
    base64 -w0
    ;;
  "edit item")
    base64 -d | jq -r '.notes' >"$VAULT_NOTES_FILE"
    ;;
  "lock ")
    echo "UNEXPECTED bw lock (caller-provided session must not be relocked)" >&2
    exit 7
    ;;
  *)
    echo "UNEXPECTED bw call: $*" >&2
    exit 9
    ;;
esac
EOF
chmod +x "$TMP/bin/bw"
export PATH="$TMP/bin:$PATH"
export EXPECT_ITEM='codex-auth-token'
export BW_SESSION='fake-session'   # ensure_bw_session reuses this, no unlock

# Each case runs in a fresh sandbox: its own CODEX_AUTH path + vault file.
run_sync() {
  # usage: run_sync <local-auth-contents|-> <vault-notes-contents|-> ARGS...
  local local_contents="$1" vault_contents="$2"; shift 2
  CODEX_AUTH="$TMP/auth.json"
  VAULT_NOTES_FILE="$TMP/vault-notes"
  export CODEX_AUTH VAULT_NOTES_FILE
  rm -f "$CODEX_AUTH" "$VAULT_NOTES_FILE"
  [ "$local_contents" = '-' ] || printf '%s' "$local_contents" >"$CODEX_AUTH"
  [ "$vault_contents" = '-' ] || printf '%s' "$vault_contents" >"$VAULT_NOTES_FILE"
  set +e
  OUT="$(bash "$SYNC" "$@" 2>&1)"; STATUS=$?
  set -e
}

# --- push: valid local auth.json -> vault Notes updated ----------------------
run_sync "$VALID_AUTH" "$OTHER_VALID" push
[ "$STATUS" -eq 0 ] || fail "push valid: expected success, got $STATUS ($OUT)"
[ "$(cat "$VAULT_NOTES_FILE")" = "$VALID_AUTH" ] || fail "push valid: vault Notes not updated to local auth"

# --- push: invalid local auth.json -> refuse, vault untouched ----------------
run_sync "$INVALID_AUTH" "$OTHER_VALID" push
[ "$STATUS" -ne 0 ] || fail "push invalid: expected failure"
[ "$(cat "$VAULT_NOTES_FILE")" = "$OTHER_VALID" ] || fail "push invalid: vault Notes must be untouched"

# --- push: no local auth.json -> refuse --------------------------------------
run_sync - "$OTHER_VALID" push
[ "$STATUS" -ne 0 ] || fail "push missing: expected failure"

# --- pull --force: valid vault note -> local overwritten (chmod 600) ---------
run_sync "$VALID_AUTH" "$OTHER_VALID" pull --force
[ "$STATUS" -eq 0 ] || fail "pull --force: expected success, got $STATUS ($OUT)"
[ "$(cat "$CODEX_AUTH")" = "$OTHER_VALID" ] || fail "pull --force: local auth not overwritten from vault"
perms="$(stat -c '%a' "$CODEX_AUTH")"
[ "$perms" = 600 ] || fail "pull --force: expected mode 600, got $perms"

# --- pull WITHOUT --force -> refuse, local auth untouched --------------------
run_sync "$VALID_AUTH" "$OTHER_VALID" pull
[ "$STATUS" -ne 0 ] || fail "pull no-force: expected failure (guard)"
[ "$(cat "$CODEX_AUTH")" = "$VALID_AUTH" ] || fail "pull no-force: local auth must be untouched"

# --- pull --force: invalid vault note -> refuse, local auth untouched --------
run_sync "$VALID_AUTH" "$INVALID_AUTH" pull --force
[ "$STATUS" -ne 0 ] || fail "pull invalid-vault: expected failure"
[ "$(cat "$CODEX_AUTH")" = "$VALID_AUTH" ] || fail "pull invalid-vault: local auth must be untouched"

# --- unknown mode -> usage/nonzero -------------------------------------------
run_sync "$VALID_AUTH" "$OTHER_VALID" frobnicate
[ "$STATUS" -ne 0 ] || fail "unknown mode: expected failure"

echo "PASS: codex-auth-sync.test.sh"
