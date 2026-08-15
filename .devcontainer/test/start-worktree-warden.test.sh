#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/.devcontainer/start-worktree-warden.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f $SCRIPT ]] || fail "start-worktree-warden.sh missing: $SCRIPT"

# --- stub external commands ---------------------------------------------
# Same idiom image-smoke.sh's source_test uses: fake executables in a temp
# dir prepended to PATH. The tmux stub records every invocation (for
# asserting new-session was/wasn't called and what args it got) and its
# `has-session` behavior is controlled by a sentinel flag file so a test can
# simulate "session already running" vs "not running" without a real tmux.
STUB_DIR="$TMP/stubs"
mkdir -p "$STUB_DIR"

TMUX_LOG="$TMP/tmux.log"
SESSION_FLAG="$TMP/session-exists"
NEWSESSION_FAIL_FLAG="$TMP/newsession-should-fail"

cat > "$STUB_DIR/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_TEST_LOG"
if [[ "${1:-}" == has-session ]]; then
  if [[ -f "$TMUX_SESSION_FLAG" ]]; then
    exit 0
  else
    exit 1
  fi
fi
if [[ "${1:-}" == new-session ]] && [[ -f "$TMUX_NEWSESSION_FAIL_FLAG" ]]; then
  echo "tmux: stub-simulated failure" >&2
  exit 17
fi
exit 0
EOF
chmod +x "$STUB_DIR/tmux"

cat > "$STUB_DIR/worktree-warden" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$STUB_DIR/worktree-warden"

STUB_PATH="$STUB_DIR:$PATH"
WORKSPACE_DIR="$TMP/ws"
mkdir -p "$WORKSPACE_DIR"
# A real repo so the script's git-common-dir resolution (used to find
# warden.log) exercises the actual code path rather than failing silently.
git -C "$WORKSPACE_DIR" init -q

setup_creds() {
  local home_dir=$1
  mkdir -p "$home_dir/.config/github-app"
  printf 'dummy-key\n' > "$home_dir/.config/github-app/private-key.pem"
  printf '4217970\n' > "$home_dir/.config/github-app/app-id"
}

new_session_count() {
  [[ -f $TMUX_LOG ]] || { printf '0'; return; }
  grep -c '^new-session' "$TMUX_LOG" || true
}

# run_script MARKER HOME PATH_VALUE
# Sets exit status in $STATUS, output in $TMP/out.log.
run_script() {
  local marker=$1 home_dir=$2 path_value=$3
  set +e
  TMUX_TEST_LOG="$TMUX_LOG" TMUX_SESSION_FLAG="$SESSION_FLAG" \
    TMUX_NEWSESSION_FAIL_FLAG="$NEWSESSION_FAIL_FLAG" \
    AGENT_SETUP_MARKER="$marker" HOME="$home_dir" WORKSPACE="$WORKSPACE_DIR" \
    PATH="$path_value" \
    bash "$SCRIPT" > "$TMP/out.log" 2>&1
  STATUS=$?
  set -e
}

# =========================================================================
# Case 1: AGENT_SETUP_MARKER points at a nonexistent path (marker absent).
# Must short-circuit before ever touching tmux -> zero new-session calls,
# and per the spec, ideally zero tmux invocations of any kind.
# =========================================================================
rm -f "$TMUX_LOG" "$SESSION_FLAG"
CASE1_HOME="$TMP/case1-home"
setup_creds "$CASE1_HOME"
run_script "$TMP/case1/no-such-marker" "$CASE1_HOME" "$STUB_PATH"
[[ $STATUS -eq 0 ]] || fail "case 1: script exited $STATUS, expected 0. Output: $(cat "$TMP/out.log")"
[[ "$(new_session_count)" -eq 0 ]] || fail "case 1: expected zero new-session calls"
[[ -f $TMUX_LOG ]] && fail "case 1: expected zero tmux invocations at all (marker check should short-circuit first)"

# =========================================================================
# Case 2: marker present, but GitHub App creds missing/incomplete.
# =========================================================================
rm -f "$TMUX_LOG" "$SESSION_FLAG"
CASE2_MARKER="$TMP/case2/marker"
mkdir -p "$(dirname "$CASE2_MARKER")"
printf 'agent-setup-complete\n' > "$CASE2_MARKER"
CASE2_HOME="$TMP/case2-home"
mkdir -p "$CASE2_HOME"
run_script "$CASE2_MARKER" "$CASE2_HOME" "$STUB_PATH"
[[ $STATUS -eq 0 ]] || fail "case 2: script exited $STATUS, expected 0. Output: $(cat "$TMP/out.log")"
[[ "$(new_session_count)" -eq 0 ]] || fail "case 2: expected zero new-session calls"

# =========================================================================
# Case 3: marker present, App creds present, worktree-warden NOT on PATH.
# =========================================================================
rm -f "$TMUX_LOG" "$SESSION_FLAG"
CASE3_MARKER="$TMP/case3/marker"
mkdir -p "$(dirname "$CASE3_MARKER")"
printf 'agent-setup-complete\n' > "$CASE3_MARKER"
CASE3_HOME="$TMP/case3-home"
setup_creds "$CASE3_HOME"
# Deliberately exclude STUB_DIR from PATH so worktree-warden is unresolvable.
run_script "$CASE3_MARKER" "$CASE3_HOME" "$PATH"
[[ $STATUS -eq 0 ]] || fail "case 3: script exited $STATUS, expected 0. Output: $(cat "$TMP/out.log")"
[[ "$(new_session_count)" -eq 0 ]] || fail "case 3: expected zero new-session calls"

# =========================================================================
# Case 4: everything present, no existing tmux session -> exactly one
# new-session call, including -s worktree-warden and -c "$WORKSPACE".
# =========================================================================
rm -f "$TMUX_LOG" "$SESSION_FLAG"
CASE4_MARKER="$TMP/case4/marker"
mkdir -p "$(dirname "$CASE4_MARKER")"
printf 'agent-setup-complete\n' > "$CASE4_MARKER"
CASE4_HOME="$TMP/case4-home"
setup_creds "$CASE4_HOME"
run_script "$CASE4_MARKER" "$CASE4_HOME" "$STUB_PATH"
[[ $STATUS -eq 0 ]] || fail "case 4: script exited $STATUS, expected 0. Output: $(cat "$TMP/out.log")"
[[ "$(new_session_count)" -eq 1 ]] || fail "case 4: expected exactly one new-session call, got $(new_session_count). Log: $(cat "$TMUX_LOG" 2>/dev/null)"
new_session_line="$(grep '^new-session' "$TMUX_LOG")"
grep -Fq -- '-s worktree-warden' <<<"$new_session_line" || fail "case 4: new-session args missing -s worktree-warden: $new_session_line"
grep -Fq -- "-c $WORKSPACE_DIR" <<<"$new_session_line" || fail "case 4: new-session args missing -c $WORKSPACE_DIR: $new_session_line"
# worktree-warden only ever writes to warden.log, never stdout/stderr (see
# its src/log.js) -- the tmux pane must tail that file alongside the daemon
# or issue #63's "print the failure immediately in the Warden tmux output"
# requirement is unmet. Assert the wrapper actually does this instead of
# just execing worktree-warden bare.
grep -Fq -- 'tail -n0 -F' <<<"$new_session_line" || fail "case 4: new-session command does not tail warden.log: $new_session_line"
grep -Fq -- 'worktree-warden' <<<"$new_session_line" || fail "case 4: new-session command does not run worktree-warden: $new_session_line"
grep -Fq -- 'worktree-warden/warden.log' <<<"$new_session_line" || fail "case 4: new-session command does not reference the state dir's warden.log: $new_session_line"

# =========================================================================
# Case 5: same as case 4 but a session already exists -> zero new-session
# calls (dedup / primary duplicate-prevention layer).
# =========================================================================
rm -f "$TMUX_LOG"
touch "$SESSION_FLAG"
CASE5_MARKER="$TMP/case5/marker"
mkdir -p "$(dirname "$CASE5_MARKER")"
printf 'agent-setup-complete\n' > "$CASE5_MARKER"
CASE5_HOME="$TMP/case5-home"
setup_creds "$CASE5_HOME"
run_script "$CASE5_MARKER" "$CASE5_HOME" "$STUB_PATH"
[[ $STATUS -eq 0 ]] || fail "case 5: script exited $STATUS, expected 0. Output: $(cat "$TMP/out.log")"
[[ "$(new_session_count)" -eq 0 ]] || fail "case 5: expected zero new-session calls (session already exists)"
rm -f "$SESSION_FLAG"

# =========================================================================
# Case 6: worktree-warden is installed ONLY under $HOME/.npm-global/bin
# (not on the generic stub PATH) -- proves the script prepends that dir
# itself rather than relying on postStartCommand's non-interactive process
# to have sourced .bashrc (it never does).
# =========================================================================
rm -f "$TMUX_LOG" "$SESSION_FLAG"
CASE6_MARKER="$TMP/case6/marker"
mkdir -p "$(dirname "$CASE6_MARKER")"
printf 'agent-setup-complete\n' > "$CASE6_MARKER"
CASE6_HOME="$TMP/case6-home"
setup_creds "$CASE6_HOME"
mkdir -p "$CASE6_HOME/.npm-global/bin"
cat > "$CASE6_HOME/.npm-global/bin/worktree-warden" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$CASE6_HOME/.npm-global/bin/worktree-warden"
# STUB_PATH still carries STUB_DIR's own worktree-warden stub (needed
# alongside the tmux/git stubs) -- what actually proves the fix is that the
# script's internal `export PATH="$HOME/.npm-global/bin:$PATH"` runs BEFORE
# the `command -v worktree-warden` check, so resolution order alone can't
# tell this case apart from case 4. What case 4 doesn't cover is that the
# prepend uses this test's CASE6_HOME, not the real container's $HOME -- run
# it with a $HOME that has no other worktree-warden anywhere but
# .npm-global/bin to confirm the prepend is what's doing the finding.
STUB_PATH_NO_WW="$TMP/stubs-no-ww:$PATH"
mkdir -p "$TMP/stubs-no-ww"
cp "$STUB_DIR/tmux" "$TMP/stubs-no-ww/tmux"
run_script "$CASE6_MARKER" "$CASE6_HOME" "$STUB_PATH_NO_WW"
[[ $STATUS -eq 0 ]] || fail "case 6: script exited $STATUS, expected 0. Output: $(cat "$TMP/out.log")"
[[ "$(new_session_count)" -eq 1 ]] || fail "case 6: expected exactly one new-session call (worktree-warden should resolve via \$HOME/.npm-global/bin), got $(new_session_count). Output: $(cat "$TMP/out.log")"

# =========================================================================
# Case 7: tmux new-session itself fails (e.g. tmux server unreachable).
# Must still exit 0 (never block postStartCommand / container entry) but
# must NOT claim success, and must say something is wrong.
# =========================================================================
rm -f "$TMUX_LOG" "$SESSION_FLAG"
touch "$NEWSESSION_FAIL_FLAG"
CASE7_MARKER="$TMP/case7/marker"
mkdir -p "$(dirname "$CASE7_MARKER")"
printf 'agent-setup-complete\n' > "$CASE7_MARKER"
CASE7_HOME="$TMP/case7-home"
setup_creds "$CASE7_HOME"
run_script "$CASE7_MARKER" "$CASE7_HOME" "$STUB_PATH"
[[ $STATUS -eq 0 ]] || fail "case 7: script exited $STATUS, expected 0 (must never block postStartCommand). Output: $(cat "$TMP/out.log")"
out="$(cat "$TMP/out.log")"
[[ "$out" != *"started in tmux session"* ]] || fail "case 7: falsely claimed success despite tmux new-session failing: $out"
[[ "$out" == *"failed to start"* ]] || fail "case 7: expected a failure message when tmux new-session fails, got: $out"
rm -f "$NEWSESSION_FAIL_FLAG"

echo "PASS: start-worktree-warden.test.sh"
