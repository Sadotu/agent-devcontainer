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
EMPTY_REFRESH='{"tokens":{"refresh_token":""}}'
NULL_REFRESH='{"tokens":{"refresh_token":null}}'
NONSTRING_REFRESH='{"tokens":{"refresh_token":false}}'

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
  "login --check")
    exit 0
    ;;
  "unlock ")
    echo 'export BW_SESSION="owned-session"'
    ;;
  "sync --session")
    count="$(cat "$BW_SYNC_COUNT_FILE" 2>/dev/null || echo 0)"
    printf '%s\n' "$((count + 1))" >"$BW_SYNC_COUNT_FILE"
    [ "${BW_SYNC_FAIL:-0}" = 0 ]
    ;;
  "encode ")
    base64 -w0
    ;;
  "edit item")
    base64 -d | jq -r '.notes' >"$VAULT_NOTES_FILE"
    ;;
  "lock ")
    count="$(cat "$LOCK_FILE" 2>/dev/null || echo 0)"
    printf '%s\n' "$((count + 1))" >"$LOCK_FILE"
    ;;
  *)
    echo "UNEXPECTED bw call: $*" >&2
    exit 9
    ;;
esac
EOF
chmod +x "$TMP/bin/bw"
# Inject a post-replacement verification failure for container-side pull.
# Shared atomic installer must restore old auth and remove operation residue.
cat >"$TMP/bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source_arg="${@: -2:1}"
destination_arg="${@: -1}"
if [ "${FAKE_CONTAINER_REPLACE_FAIL:-0}" = 1 ] &&
   [[ "$source_arg" == */.auth.json.tmp.* ]] &&
   [ "$destination_arg" = "$CODEX_AUTH" ]; then
  exit 96
fi
/bin/mv "$@"
if [ "${FAKE_CONTAINER_VERIFY_FAIL:-0}" = 1 ] &&
   [[ "$source_arg" == */.auth.json.tmp.* ]] &&
   [ "$destination_arg" = "$CODEX_AUTH" ]; then
  chmod 644 "$destination_arg"
fi
EOF
chmod +x "$TMP/bin/mv"
export PATH="$TMP/bin:$PATH"
export EXPECT_ITEM='codex-auth-token'
export BW_SESSION='fake-session'   # ensure_bw_session reuses this, no unlock

# Each case runs in a fresh sandbox: its own CODEX_AUTH path + vault file.
run_sync() {
  # usage: run_sync <local-auth-contents|-> <vault-notes-contents|-> ARGS...
  local local_contents="$1" vault_contents="$2"; shift 2
  CODEX_AUTH="$TMP/auth.json"
  VAULT_NOTES_FILE="$TMP/vault-notes"
  LOCK_FILE="$TMP/bw-locked"
  BW_SYNC_COUNT_FILE="$TMP/bw-sync-count"
  export CODEX_AUTH VAULT_NOTES_FILE LOCK_FILE BW_SYNC_COUNT_FILE
  rm -f "$CODEX_AUTH" "$VAULT_NOTES_FILE" "$LOCK_FILE" "$BW_SYNC_COUNT_FILE" "$TMP"/.auth.json.tmp.*
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
[ ! -e "$LOCK_FILE" ] || fail "push valid: caller-provided session must not be relocked"
[ "$(cat "$BW_SYNC_COUNT_FILE")" = 1 ] || fail "push valid: expected exactly one bw sync"

# --- bw sync failure: fatal sync preserves local/vault state -----------------
BW_SYNC_FAIL=1 run_sync "$VALID_AUTH" "$OTHER_VALID" push
[ "$STATUS" -ne 0 ] || fail "push bw sync failure: expected failure"
[ "$(cat "$VAULT_NOTES_FILE")" = "$OTHER_VALID" ] || fail "push bw sync failure: vault changed"
BW_SYNC_FAIL=1 run_sync "$VALID_AUTH" "$OTHER_VALID" pull --force
[ "$STATUS" -ne 0 ] || fail "pull bw sync failure: expected failure"
[ "$(cat "$CODEX_AUTH")" = "$VALID_AUTH" ] || fail "pull bw sync failure: local auth changed"
unset BW_SYNC_FAIL

# Fatal sync failure after helper-owned unlock must not leave vault unlocked.
unset BW_SESSION
BW_SYNC_FAIL=1 run_sync "$VALID_AUTH" "$OTHER_VALID" pull --force
[ "$STATUS" -ne 0 ] || fail "owned unlock sync failure: expected failure"
[ -f "$LOCK_FILE" ] || fail "owned unlock sync failure: vault must be relocked"
[ "$(cat "$LOCK_FILE")" = 1 ] || fail "owned unlock sync failure: vault relocked more than once"
export BW_SESSION='fake-session'
unset BW_SYNC_FAIL

# --- push: invalid local auth.json -> refuse, vault untouched ----------------
run_sync "$INVALID_AUTH" "$OTHER_VALID" push
[ "$STATUS" -ne 0 ] || fail "push invalid: expected failure"
[ "$(cat "$VAULT_NOTES_FILE")" = "$OTHER_VALID" ] || fail "push invalid: vault Notes must be untouched"

for invalid_case in "$EMPTY_REFRESH" "$NULL_REFRESH" "$NONSTRING_REFRESH"; do
  run_sync "$invalid_case" "$OTHER_VALID" push
  [ "$STATUS" -ne 0 ] || fail "push strict invalid: expected failure"
  [ "$(cat "$VAULT_NOTES_FILE")" = "$OTHER_VALID" ] || fail "push strict invalid: vault Notes changed"
done

# --- push: no local auth.json -> refuse --------------------------------------
run_sync - "$OTHER_VALID" push
[ "$STATUS" -ne 0 ] || fail "push missing: expected failure"

# --- pull --force: valid vault note -> local overwritten (chmod 600) ---------
run_sync "$VALID_AUTH" "$OTHER_VALID" pull --force
[ "$STATUS" -eq 0 ] || fail "pull --force: expected success, got $STATUS ($OUT)"
[ "$(cat "$CODEX_AUTH")" = "$OTHER_VALID" ] || fail "pull --force: local auth not overwritten from vault"
perms="$(stat -c '%a' "$CODEX_AUTH")"
[ "$perms" = 600 ] || fail "pull --force: expected mode 600, got $perms"
if find "$TMP" -maxdepth 1 \( -name '.auth.json.tmp.*' -o -name '.auth.json.bak.*' \) | grep -q .; then
  fail "pull --force success: staging or backup residue remains"
fi

# --- pull replacement failure -> old auth restored, no residue --------------
FAKE_CONTAINER_REPLACE_FAIL=1 run_sync "$VALID_AUTH" "$OTHER_VALID" pull --force
[ "$STATUS" -ne 0 ] || fail "pull replacement failure: expected failure"
[ "$(cat "$CODEX_AUTH")" = "$VALID_AUTH" ] || fail "pull replacement failure: old auth not restored"
if find "$TMP" -maxdepth 1 \( -name '.auth.json.tmp.*' -o -name '.auth.json.bak.*' \) | grep -q .; then
  fail "pull replacement failure: staging or backup residue remains"
fi
unset FAKE_CONTAINER_REPLACE_FAIL

# --- pull install verification failure -> old auth restored, no residue ------
FAKE_CONTAINER_VERIFY_FAIL=1 run_sync "$VALID_AUTH" "$OTHER_VALID" pull --force
[ "$STATUS" -ne 0 ] || fail "pull install verification failure: expected failure"
[ "$(cat "$CODEX_AUTH")" = "$VALID_AUTH" ] || fail "pull install verification failure: old auth not restored"
if find "$TMP" -maxdepth 1 \( -name '.auth.json.tmp.*' -o -name '.auth.json.bak.*' \) | grep -q .; then
  fail "pull install verification failure: staging or backup residue remains"
fi
unset FAKE_CONTAINER_VERIFY_FAIL

# --- pull WITHOUT --force -> refuse, local auth untouched --------------------
run_sync "$VALID_AUTH" "$OTHER_VALID" pull
[ "$STATUS" -ne 0 ] || fail "pull no-force: expected failure (guard)"
[ "$(cat "$CODEX_AUTH")" = "$VALID_AUTH" ] || fail "pull no-force: local auth must be untouched"

# --- pull --force: invalid vault note -> refuse, local auth untouched --------
run_sync "$VALID_AUTH" "$INVALID_AUTH" pull --force
[ "$STATUS" -ne 0 ] || fail "pull invalid-vault: expected failure"
[ "$(cat "$CODEX_AUTH")" = "$VALID_AUTH" ] || fail "pull invalid-vault: local auth must be untouched"

for invalid_case in "$EMPTY_REFRESH" "$NULL_REFRESH" "$NONSTRING_REFRESH"; do
  run_sync "$VALID_AUTH" "$invalid_case" pull --force
  [ "$STATUS" -ne 0 ] || fail "pull strict invalid vault: expected failure"
  [ "$(cat "$CODEX_AUTH")" = "$VALID_AUTH" ] || fail "pull strict invalid vault: local auth changed"
done

# --- failure after helper-owned unlock -> vault relocked ---------------------
unset BW_SESSION
run_sync "$VALID_AUTH" "$INVALID_AUTH" pull --force
[ "$STATUS" -ne 0 ] || fail "pull invalid owned session: expected failure"
[ -f "$LOCK_FILE" ] || fail "pull invalid owned session: vault must be relocked"
! grep -Fq 'owned-session' <<<"$OUT" || fail "pull owned session: BW_SESSION leaked to command output"
export BW_SESSION='fake-session'

# --- unknown mode -> usage/nonzero -------------------------------------------
run_sync "$VALID_AUTH" "$OTHER_VALID" frobnicate
[ "$STATUS" -ne 0 ] || fail "unknown mode: expected failure"

echo "PASS: codex-auth-sync.test.sh"

# --- host dc: validated helper handoff updates host/global auth -------------
# Fake host prerequisites and devcontainer execution. The fake container helper
# emits its already-validated value only through internal handoff stdout, which
# dc redirects into private staging; captured terminal output has no credential.
DC="$ROOT/.devcontainer/dc"
HOST_TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$HOST_TMP"' EXIT
mkdir -p "$HOST_TMP/bin" "$HOST_TMP/home/.codex"
cat >"$HOST_TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$HOST_TMP/bin/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
last="${!#}"
if [ "${FAKE_BAD_INSTALLED_MODE:-0}" = 1 ] && [ "$last" = "$CODEX_HOME/auth.json" ]; then
  printf '644\n'
else
  /usr/bin/stat "$@"
fi
EOF
cat >"$HOST_TMP/bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source_arg="${@: -2:1}"
if [ "${FAKE_HOST_ROLLBACK_FAIL:-0}" = 1 ] && [[ "$source_arg" == */.codex-auth-backup.* ]]; then
  exit 95
fi
/bin/mv "$@"
EOF
cat >"$HOST_TMP/bin/devcontainer" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = exec ] || exit 90
shift
while [ "$1" != env ]; do shift; done
shift
case "$1" in
  CODEX_AUTH_HANDOFF=stdout) ;;
  *) exit 91 ;;
esac
export CODEX_AUTH_HANDOFF=stdout
shift
[ "$1" = /opt/agent-devcontainer/codex-auth-sync.sh ] || exit 92
shift
if [ "${FAKE_REAL_HELPER:-0}" = 1 ]; then
  exec bash "$SYNC" "$@"
fi
printf '%s\n' "$1" >>"$FAKE_CALLS"
[ "${FAKE_FAIL_BEFORE_HANDOFF:-0}" = 0 ] || exit 93
printf '%s\n' "$FAKE_AUTH"
[ "${FAKE_FAIL_AFTER_HANDOFF:-0}" = 0 ] || exit 94
EOF
chmod +x "$HOST_TMP/bin/docker" "$HOST_TMP/bin/devcontainer" "$HOST_TMP/bin/stat" "$HOST_TMP/bin/mv"
mkdir -p "$HOST_TMP/global-codex"

run_dc() {
  local command="$1"; shift
  export HOME="$HOST_TMP/home" CODEX_HOME="$HOST_TMP/global-codex"
  export FAKE_WORKSPACE="$ROOT" FAKE_CALLS="$HOST_TMP/calls"
  export SYNC
  export FAKE_AUTH="${FAKE_AUTH:-$OTHER_VALID}"
  mkdir -p "$CODEX_HOME"
  rm -f "$FAKE_CALLS"
  set +e
  DC_OUT="$(PATH="$HOST_TMP/bin:$PATH" bash "$DC" "$command" "$@" 2>&1)"; DC_STATUS=$?
  set -e
}

printf '%s\n' "$VALID_AUTH" >"$HOST_TMP/global-codex/auth.json"
chmod 600 "$HOST_TMP/global-codex/auth.json"
FAKE_AUTH="$OTHER_VALID" run_dc codex-push
[ "$DC_STATUS" -eq 0 ] || fail "dc codex-push: expected success, got $DC_STATUS ($DC_OUT)"
[ "$(cat "$HOST_TMP/global-codex/auth.json")" = "$OTHER_VALID" ] || fail "dc codex-push: host auth not updated from validated handoff"
[ "$(stat -c '%a' "$HOST_TMP/global-codex/auth.json")" = 600 ] || fail "dc codex-push: host auth mode not 600"
! grep -Fq 'rt-NEW' <<<"$DC_OUT" || fail "dc codex-push: credential leaked to output"

# Real helper status must not mix with JSON-only handoff stdout.
printf '%s' "$OTHER_VALID" >"$CODEX_AUTH"
printf '%s' "$VALID_AUTH" >"$VAULT_NOTES_FILE"
FAKE_REAL_HELPER=1 run_dc codex-push
[ "$DC_STATUS" -eq 0 ] || fail "dc real helper handoff: expected success, got $DC_STATUS ($DC_OUT)"
[ "$(cat "$HOST_TMP/global-codex/auth.json")" = "$OTHER_VALID" ] || fail "dc real helper handoff: host auth not updated"
unset FAKE_REAL_HELPER

printf '%s\n' "$VALID_AUTH" >"$HOST_TMP/global-codex/auth.json"
FAKE_AUTH="$OTHER_VALID" run_dc codex-pull --force
[ "$DC_STATUS" -eq 0 ] || fail "dc codex-pull: expected success, got $DC_STATUS ($DC_OUT)"
[ "$(cat "$HOST_TMP/global-codex/auth.json")" = "$OTHER_VALID" ] || fail "dc codex-pull: host auth not updated"
[ "$(grep -c '^pull$' "$FAKE_CALLS")" -eq 1 ] || fail "dc codex-pull: expected one vault retrieval"

# Invalid/mis-permissioned handoff refuses replacement and leaves no residue.
printf '%s\n' "$VALID_AUTH" >"$HOST_TMP/global-codex/auth.json"
FAKE_AUTH="$INVALID_AUTH" run_dc codex-push
[ "$DC_STATUS" -ne 0 ] || fail "dc invalid handoff: expected failure"
[ "$(cat "$HOST_TMP/global-codex/auth.json")" = "$VALID_AUTH" ] || fail "dc invalid handoff: host auth changed"
# Failure after handoff keeps old host auth. Successful operation removes its
# staging file and operation-only backup.
FAKE_AUTH="$OTHER_VALID" FAKE_FAIL_AFTER_HANDOFF=1 run_dc codex-pull --force
[ "$DC_STATUS" -ne 0 ] || fail "dc helper failure: expected failure"
[ "$(cat "$HOST_TMP/global-codex/auth.json")" = "$VALID_AUTH" ] || fail "dc helper failure: host auth changed"
unset FAKE_FAIL_AFTER_HANDOFF

# Post-install verification failure restores operation backup.
FAKE_AUTH="$OTHER_VALID" FAKE_BAD_INSTALLED_MODE=1 run_dc codex-push
[ "$DC_STATUS" -ne 0 ] || fail "dc host verification failure: expected failure"
[ "$(cat "$HOST_TMP/global-codex/auth.json")" = "$VALID_AUTH" ] || fail "dc host verification failure: previous auth not restored"
unset FAKE_BAD_INSTALLED_MODE

# Failed rollback retains sole old-auth backup and reports exact path.
printf '%s\n' "$VALID_AUTH" >"$HOST_TMP/global-codex/auth.json"
FAKE_AUTH="$OTHER_VALID" FAKE_BAD_INSTALLED_MODE=1 FAKE_HOST_ROLLBACK_FAIL=1 run_dc codex-push
[ "$DC_STATUS" -ne 0 ] || fail "dc rollback failure: expected failure"
retained_backup="$(sed -n 's/^ERROR: failed to restore previous host Codex auth from \(.*\)\.$/\1/p' <<<"$DC_OUT")"
[ -n "$retained_backup" ] || fail "dc rollback failure: retained backup path not reported ($DC_OUT)"
[ -f "$retained_backup" ] || fail "dc rollback failure: sole old-auth backup was deleted"
[ "$(cat "$retained_backup")" = "$VALID_AUTH" ] || fail "dc rollback failure: retained backup changed"
rm -f -- "$retained_backup"
unset FAKE_BAD_INSTALLED_MODE FAKE_HOST_ROLLBACK_FAIL
if find "$HOST_TMP/global-codex" -maxdepth 1 \( -name '.codex-auth-handoff.*' -o -name '.codex-auth-backup.*' -o -name '.auth.json.stage.*' \) | grep -q .; then
  fail "dc sync: staging or backup residue remains"
fi

echo "PASS: dc Codex host-auth sync"
