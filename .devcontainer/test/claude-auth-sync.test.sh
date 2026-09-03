#!/usr/bin/env bash
# Drives claude-auth-sync.sh push/pull against a fake `bw` vault. The
# interactive unlock is bypassed by pre-setting BW_SESSION (a caller-provided
# session, which ensure_bw_session reuses verbatim) — so these tests cover the
# push/pull logic and the token-validity gate applied in both directions,
# without the TTY login path. Mirrors codex-auth-sync.test.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SYNC="$ROOT/.devcontainer/claude-auth-sync.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

VALID_TOKEN='sk-ant-oat01-abc123'
OTHER_VALID_TOKEN='sk-ant-oat01-NEW456'
INVALID_TOKEN='not-a-claude-token'
EMPTY_TOKEN=''
WHITESPACE_TOKEN='sk-ant-oat01 with space'

# --- Fake bw: a single-item vault whose Notes live in $VAULT_NOTES_FILE ------
mkdir -p "$TMP/bin"
cat >"$TMP/bin/bw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1 ${2:-}" in
  "get item")
    [ "$3" = "$EXPECT_ITEM" ] || exit 1
    notes="$(cat "$VAULT_NOTES_FILE" 2>/dev/null || true)"
    jq -n --arg id 'item-id-123' --arg n "$notes" '{id:$id,name:"claude-code-oauth-token",notes:$n}'
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
# Shared atomic installer must restore old oauth-env and remove residue.
cat >"$TMP/bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source_arg="${@: -2:1}"
destination_arg="${@: -1}"
if [ "${FAKE_CONTAINER_REPLACE_FAIL:-0}" = 1 ] &&
   [[ "$source_arg" == */.oauth-env.tmp.* ]] &&
   [ "$destination_arg" = "$CLAUDE_OAUTH_ENV" ]; then
  exit 96
fi
/bin/mv "$@"
if [ "${FAKE_CONTAINER_VERIFY_FAIL:-0}" = 1 ] &&
   [[ "$source_arg" == */.oauth-env.tmp.* ]] &&
   [ "$destination_arg" = "$CLAUDE_OAUTH_ENV" ]; then
  chmod 644 "$destination_arg"
fi
EOF
chmod +x "$TMP/bin/mv"
export PATH="$TMP/bin:$PATH"
export EXPECT_ITEM='claude-code-oauth-token'
export BW_SESSION='fake-session'   # ensure_bw_session reuses this, no unlock

# Each case runs in a fresh sandbox: its own CLAUDE_OAUTH_ENV path + vault file
# + isolated $HOME (do_pull seeds ~/.claude.json there).
run_sync() {
  # usage: run_sync <local-token|-> <vault-notes-contents|-> ARGS...
  local local_contents="$1" vault_contents="$2"; shift 2
  CLAUDE_OAUTH_ENV="$TMP/oauth-env"
  VAULT_NOTES_FILE="$TMP/vault-notes"
  LOCK_FILE="$TMP/bw-locked"
  BW_SYNC_COUNT_FILE="$TMP/bw-sync-count"
  HOME="$TMP/home"
  export CLAUDE_OAUTH_ENV VAULT_NOTES_FILE LOCK_FILE BW_SYNC_COUNT_FILE HOME
  rm -rf "$HOME"
  mkdir -p "$HOME"
  rm -f "$CLAUDE_OAUTH_ENV" "$VAULT_NOTES_FILE" "$LOCK_FILE" "$BW_SYNC_COUNT_FILE" "$TMP"/.oauth-env.tmp.*
  unset CLAUDE_CODE_OAUTH_TOKEN
  if [ "$local_contents" != '-' ]; then
    printf 'export CLAUDE_CODE_OAUTH_TOKEN=%q\n' "$local_contents" >"$CLAUDE_OAUTH_ENV"
  fi
  [ "$vault_contents" = '-' ] || printf '%s' "$vault_contents" >"$VAULT_NOTES_FILE"
  set +e
  OUT="$(bash "$SYNC" "$@" 2>&1)"; STATUS=$?
  set -e
}

# --- push: valid local token -> vault Notes updated ---------------------------
run_sync "$VALID_TOKEN" "$OTHER_VALID_TOKEN" push
[ "$STATUS" -eq 0 ] || fail "push valid: expected success, got $STATUS ($OUT)"
[ "$(cat "$VAULT_NOTES_FILE")" = "$VALID_TOKEN" ] || fail "push valid: vault Notes not updated to local token"
[ ! -e "$LOCK_FILE" ] || fail "push valid: caller-provided session must not be relocked"
[ "$(cat "$BW_SYNC_COUNT_FILE")" = 1 ] || fail "push valid: expected exactly one bw sync"

# --- bw sync failure: fatal sync preserves local/vault state -----------------
BW_SYNC_FAIL=1 run_sync "$VALID_TOKEN" "$OTHER_VALID_TOKEN" push
[ "$STATUS" -ne 0 ] || fail "push bw sync failure: expected failure"
[ "$(cat "$VAULT_NOTES_FILE")" = "$OTHER_VALID_TOKEN" ] || fail "push bw sync failure: vault changed"
BW_SYNC_FAIL=1 run_sync "$VALID_TOKEN" "$OTHER_VALID_TOKEN" pull
[ "$STATUS" -ne 0 ] || fail "pull bw sync failure: expected failure"
! grep -q "CLAUDE_CODE_OAUTH_TOKEN=$OTHER_VALID_TOKEN" "$CLAUDE_OAUTH_ENV" 2>/dev/null \
  || fail "pull bw sync failure: local oauth-env changed"
unset BW_SYNC_FAIL

# Fatal sync failure after helper-owned unlock must not leave vault unlocked.
unset BW_SESSION
BW_SYNC_FAIL=1 run_sync "$VALID_TOKEN" "$OTHER_VALID_TOKEN" pull
[ "$STATUS" -ne 0 ] || fail "owned unlock sync failure: expected failure"
[ -f "$LOCK_FILE" ] || fail "owned unlock sync failure: vault must be relocked"
[ "$(cat "$LOCK_FILE")" = 1 ] || fail "owned unlock sync failure: vault relocked more than once"
export BW_SESSION='fake-session'
unset BW_SYNC_FAIL

# --- push: invalid local token -> refuse, vault untouched --------------------
run_sync "$INVALID_TOKEN" "$OTHER_VALID_TOKEN" push
[ "$STATUS" -ne 0 ] || fail "push invalid: expected failure"
[ "$(cat "$VAULT_NOTES_FILE")" = "$OTHER_VALID_TOKEN" ] || fail "push invalid: vault Notes must be untouched"

for invalid_case in "$EMPTY_TOKEN" "$WHITESPACE_TOKEN"; do
  run_sync "$invalid_case" "$OTHER_VALID_TOKEN" push
  [ "$STATUS" -ne 0 ] || fail "push strict invalid: expected failure ($invalid_case)"
  [ "$(cat "$VAULT_NOTES_FILE")" = "$OTHER_VALID_TOKEN" ] || fail "push strict invalid: vault Notes changed"
done

# --- push: no local token -> refuse -------------------------------------------
run_sync - "$OTHER_VALID_TOKEN" push
[ "$STATUS" -ne 0 ] || fail "push missing: expected failure"

# --- pull: valid vault note -> local overwritten (chmod 600) -----------------
run_sync "$VALID_TOKEN" "$OTHER_VALID_TOKEN" pull
[ "$STATUS" -eq 0 ] || fail "pull: expected success, got $STATUS ($OUT)"
grep -q "CLAUDE_CODE_OAUTH_TOKEN=$OTHER_VALID_TOKEN" "$CLAUDE_OAUTH_ENV" \
  || fail "pull: local oauth-env not overwritten from vault"
perms="$(stat -c '%a' "$CLAUDE_OAUTH_ENV")"
[ "$perms" = 600 ] || fail "pull: expected mode 600, got $perms"
[ -s "$HOME/.claude.json" ] || fail "pull: onboarding flag not seeded"
if find "$TMP" -maxdepth 1 \( -name '.oauth-env.tmp.*' -o -name '.oauth-env.bak.*' \) | grep -q .; then
  fail "pull success: staging or backup residue remains"
fi

# --- pull: onboarding flag left alone when already present -------------------
CLAUDE_OAUTH_ENV="$TMP/oauth-env"
VAULT_NOTES_FILE="$TMP/vault-notes"
HOME="$TMP/home"
export CLAUDE_OAUTH_ENV VAULT_NOTES_FILE HOME
rm -rf "$HOME"; mkdir -p "$HOME"
rm -f "$CLAUDE_OAUTH_ENV"
printf '%s' "$OTHER_VALID_TOKEN" >"$VAULT_NOTES_FILE"
printf '{"hasCompletedOnboarding": false, "marker": "keep-me"}\n' >"$HOME/.claude.json"
OUT="$(bash "$SYNC" pull 2>&1)"; STATUS=$?
[ "$STATUS" -eq 0 ] || fail "pull with existing onboarding file: expected success ($OUT)"
grep -q 'keep-me' "$HOME/.claude.json" || fail "pull with existing onboarding file: file was overwritten"

# --- pull replacement failure -> old oauth-env restored, no residue ----------
FAKE_CONTAINER_REPLACE_FAIL=1 run_sync "$VALID_TOKEN" "$OTHER_VALID_TOKEN" pull
[ "$STATUS" -ne 0 ] || fail "pull replacement failure: expected failure"
grep -q "CLAUDE_CODE_OAUTH_TOKEN=$VALID_TOKEN" "$CLAUDE_OAUTH_ENV" \
  || fail "pull replacement failure: old oauth-env not restored"
if find "$TMP" -maxdepth 1 \( -name '.oauth-env.tmp.*' -o -name '.oauth-env.bak.*' \) | grep -q .; then
  fail "pull replacement failure: staging or backup residue remains"
fi
unset FAKE_CONTAINER_REPLACE_FAIL

# --- pull install verification failure -> old oauth-env restored, no residue -
FAKE_CONTAINER_VERIFY_FAIL=1 run_sync "$VALID_TOKEN" "$OTHER_VALID_TOKEN" pull
[ "$STATUS" -ne 0 ] || fail "pull install verification failure: expected failure"
grep -q "CLAUDE_CODE_OAUTH_TOKEN=$VALID_TOKEN" "$CLAUDE_OAUTH_ENV" \
  || fail "pull install verification failure: old oauth-env not restored"
if find "$TMP" -maxdepth 1 \( -name '.oauth-env.tmp.*' -o -name '.oauth-env.bak.*' \) | grep -q .; then
  fail "pull install verification failure: staging or backup residue remains"
fi
unset FAKE_CONTAINER_VERIFY_FAIL

# --- pull: invalid vault note -> refuse, local oauth-env untouched -----------
run_sync "$VALID_TOKEN" "$INVALID_TOKEN" pull
[ "$STATUS" -ne 0 ] || fail "pull invalid-vault: expected failure"
grep -q "CLAUDE_CODE_OAUTH_TOKEN=$VALID_TOKEN" "$CLAUDE_OAUTH_ENV" \
  || fail "pull invalid-vault: local oauth-env must be untouched"

for invalid_case in "$EMPTY_TOKEN" "$WHITESPACE_TOKEN"; do
  run_sync "$VALID_TOKEN" "$invalid_case" pull
  [ "$STATUS" -ne 0 ] || fail "pull strict invalid vault: expected failure ($invalid_case)"
  grep -q "CLAUDE_CODE_OAUTH_TOKEN=$VALID_TOKEN" "$CLAUDE_OAUTH_ENV" \
    || fail "pull strict invalid vault: local oauth-env changed"
done

# --- failure after helper-owned unlock -> vault relocked ---------------------
unset BW_SESSION
run_sync "$VALID_TOKEN" "$INVALID_TOKEN" pull
[ "$STATUS" -ne 0 ] || fail "pull invalid owned session: expected failure"
[ -f "$LOCK_FILE" ] || fail "pull invalid owned session: vault must be relocked"
! grep -Fq 'owned-session' <<<"$OUT" || fail "pull owned session: BW_SESSION leaked to command output"
export BW_SESSION='fake-session'

# --- unknown mode -> usage/nonzero -------------------------------------------
run_sync "$VALID_TOKEN" "$OTHER_VALID_TOKEN" frobnicate
[ "$STATUS" -ne 0 ] || fail "unknown mode: expected failure"

echo "PASS: claude-auth-sync.test.sh"

# --- host dc: pass-through exit status + stale-env warning -------------------
# Fake host prerequisites and devcontainer execution. dc claude-push/pull
# writes nothing under the host's HOME — unlike Codex, there is no host file
# to validate/stage, so this only checks status pass-through and the warning.
DC="$ROOT/.devcontainer/dc"
HOST_TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$HOST_TMP"' EXIT
mkdir -p "$HOST_TMP/bin"
cat >"$HOST_TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$HOST_TMP/bin/devcontainer" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = exec ] || exit 90
shift
[ "$1" = --workspace-folder ] && shift && shift
[ "$1" = /opt/agent-devcontainer/claude-auth-sync.sh ] || exit 92
shift
printf '%s\n' "$1" >>"$FAKE_CALLS"
if [ "${FAKE_HELPER_FAIL:-0}" = 1 ]; then
  echo "ERROR: fake helper failure" >&2
  exit 97
fi
echo "fake helper ok: $1"
EOF
chmod +x "$HOST_TMP/bin/docker" "$HOST_TMP/bin/devcontainer"

run_dc() {
  local command="$1"; shift
  export HOME="$HOST_TMP/home" FAKE_CALLS="$HOST_TMP/calls"
  mkdir -p "$HOME"
  rm -f "$FAKE_CALLS"
  set +e
  DC_OUT="$(PATH="$HOST_TMP/bin:$PATH" bash "$DC" "$command" "$@" 2>&1)"; DC_STATUS=$?
  set -e
}

unset CLAUDE_CODE_OAUTH_TOKEN
run_dc claude-push
[ "$DC_STATUS" -eq 0 ] || fail "dc claude-push: expected success, got $DC_STATUS ($DC_OUT)"
[ "$(cat "$FAKE_CALLS")" = push ] || fail "dc claude-push: helper not invoked with push"
! grep -Fq 'WARNING' <<<"$DC_OUT" || fail "dc claude-push: unexpected stale-env warning"

run_dc claude-pull
[ "$DC_STATUS" -eq 0 ] || fail "dc claude-pull: expected success, got $DC_STATUS ($DC_OUT)"
[ "$(cat "$FAKE_CALLS")" = pull ] || fail "dc claude-pull: helper not invoked with pull"
! grep -Fq 'WARNING' <<<"$DC_OUT" || fail "dc claude-pull without stale host env: unexpected warning"

CLAUDE_CODE_OAUTH_TOKEN='sk-ant-oat01-stale' run_dc claude-pull
[ "$DC_STATUS" -eq 0 ] || fail "dc claude-pull with stale host env: expected success, got $DC_STATUS ($DC_OUT)"
grep -Fq 'WARNING' <<<"$DC_OUT" || fail "dc claude-pull with stale host env: expected warning"
grep -Fq 'CLAUDE_CODE_OAUTH_TOKEN' <<<"$DC_OUT" || fail "dc claude-pull with stale host env: warning missing variable name"

CLAUDE_CODE_OAUTH_TOKEN='sk-ant-oat01-stale' FAKE_HELPER_FAIL=1 run_dc claude-pull
[ "$DC_STATUS" -ne 0 ] || fail "dc claude-pull helper failure: expected failure"
unset FAKE_HELPER_FAIL

echo "PASS: dc Claude auth sync"
