#!/usr/bin/env bash
# Exercises refresh-skills.sh (issue #92) in isolation: a fake WORKSPACE git
# repo, a stub dotagents-install.sh, and stub git/gh CLIs so no real npx
# download or GitHub call ever happens.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/.devcontainer/refresh-skills.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f $SCRIPT ]] || fail "refresh-skills.sh missing: $SCRIPT"

STUB_DIR="$TMP/stubs"
mkdir -p "$STUB_DIR"

GH_LOG="$TMP/gh.log"
TOKEN_LOG="$TMP/token.log"
GIT_PUSH_LOG="$TMP/git-push.log"
DOTAGENTS_LOG="$TMP/dotagents.log"

# --- stub dotagents-install.sh: writes NEW_LOCK_CONTENT into $1/agents.lock
# when set, sleeps when SLEEP_SECS is set (to exercise the timeout), and
# fails when INSTALL_FAILS is set.
cat > "$STUB_DIR/dotagents-install.sh" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$DOTAGENTS_LOG"
[ -z "${SLEEP_SECS:-}" ] || sleep "$SLEEP_SECS"
[ -z "${INSTALL_FAILS:-}" ] || { echo "dotagents: stub failure" >&2; exit 1; }
if [ -n "${NEW_LOCK_CONTENT:-}" ]; then
  printf '%s\n' "$NEW_LOCK_CONTENT" > "$1/agents.lock"
fi
exit 0
EOF
chmod +x "$STUB_DIR/dotagents-install.sh"

# --- stub gh-app-token.sh: always "succeeds" with a fake token ---
cat > "$STUB_DIR/gh-app-token.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${GITHUB_APP_REPO:-}" >> "$TOKEN_LOG"
echo "fake-token"
EOF
chmod +x "$STUB_DIR/gh-app-token.sh"

# --- stub gh: records every invocation; `pr list` result controlled by
# EXISTING_PR_URL, `pr create` "succeeds" printing a fixed URL unless
# PR_CREATE_FAILS is set ---
cat > "$STUB_DIR/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
if [ "$1" = pr ] && [ "$2" = list ]; then
  if [ -n "${EXISTING_PR_URL:-}" ]; then
    printf '%s\n' "$EXISTING_PR_URL"
  fi
  exit 0
fi
if [ "$1" = pr ] && [ "$2" = create ]; then
  [ -z "${PR_CREATE_FAILS:-}" ] || { echo "gh: stub pr create failure" >&2; exit 1; }
  echo "https://github.com/fake/repo/pull/999"
  exit 0
fi
exit 0
EOF
chmod +x "$STUB_DIR/gh"

# Production bypasses PATH-level gh shims after minting a token. Redirect that
# fixed target only in this fixture copy, avoiding a host GitHub CLI call.
TEST_SCRIPT="$TMP/refresh-skills-under-test.sh"
sed "s|/usr/bin/gh|$STUB_DIR/gh|g" "$SCRIPT" > "$TEST_SCRIPT"
chmod +x "$TEST_SCRIPT"

# --- stub git: passes through to the real git for everything except
# `push`, which is recorded and can be made to fail ---
REAL_GIT="$(command -v git)"
cat > "$STUB_DIR/git" <<EOF
#!/usr/bin/env bash
REAL_GIT="$REAL_GIT"
EOF
cat >> "$STUB_DIR/git" <<'EOF'
# refresh-skills.sh always calls git as `git -C <dir> <subcommand> ...`, so
# $1 is "-C", not the subcommand — match "push" anywhere in the argv instead.
case " $* " in
  *' push '*)
    echo "$@" >> "$GIT_PUSH_LOG"
    [ -z "${GIT_PUSH_FAILS:-}" ] || { echo "git: stub push failure" >&2; exit 1; }
    exit 0
    ;;
esac
exec "$REAL_GIT" "$@"
EOF
chmod +x "$STUB_DIR/git"

STUB_PATH="$STUB_DIR:$PATH"

# --- a real git repo standing in for the primary WORKSPACE, with a tracked
# agents.lock so `git diff -- agents.lock` / `git checkout -- agents.lock`
# behave like the real thing ---
WORKSPACE_DIR="$TMP/ws"
mkdir -p "$WORKSPACE_DIR"
git -C "$WORKSPACE_DIR" init -q -b main
git -C "$WORKSPACE_DIR" config user.email test@example.com
git -C "$WORKSPACE_DIR" config user.name "Test"
printf 'old-lock\n' > "$WORKSPACE_DIR/agents.lock"
git -C "$WORKSPACE_DIR" add agents.lock
git -C "$WORKSPACE_DIR" commit -qm "seed agents.lock"
# `git push` is stubbed above, but `refresh-skills.sh` still needs a remote
# named `origin` to push to and a real one to fetch from for `worktree add`.
REMOTE_DIR="$TMP/remote.git"
git init -q --bare "$REMOTE_DIR"
git -C "$WORKSPACE_DIR" remote add origin "$REMOTE_DIR"
# --no-verify: this pushes to a throwaway local bare repo standing in for
# `origin`, not the real project remote — the global pre-push hook installed
# by setup-agents.sh (blocks direct pushes to main) would otherwise fire here.
git -C "$WORKSPACE_DIR" push -q --no-verify origin main
git -C "$WORKSPACE_DIR" branch --set-upstream-to=origin/main main -q

GITHUB_APP_DIR="$TMP/github-app"
mkdir -p "$GITHUB_APP_DIR"
printf 'dummy-key\n' > "$GITHUB_APP_DIR/private-key.pem"
printf '1\n' > "$GITHUB_APP_DIR/app-id"

# run ENV... ; sets STATUS and OUT, never aborts the suite
run() {
  set +e
  OUT="$(env "$@" \
    WORKSPACE="$WORKSPACE_DIR" TOOLDIR="$STUB_DIR" PROJECT_NAME=proj GH_OWNER=owner \
    GITHUB_APP_DIR="$GITHUB_APP_DIR" GH_LOG="$GH_LOG" TOKEN_LOG="$TOKEN_LOG" GIT_PUSH_LOG="$GIT_PUSH_LOG" \
    DOTAGENTS_LOG="$DOTAGENTS_LOG" PATH="$STUB_PATH" \
    bash "$TEST_SCRIPT" 2>&1)"
  STATUS=$?
  set -e
}

reset_workspace() {
  git -C "$WORKSPACE_DIR" checkout -q main
  git -C "$WORKSPACE_DIR" reset -q --hard origin/main
  git -C "$WORKSPACE_DIR" clean -qfd
  : > "$GH_LOG"; : > "$TOKEN_LOG"; : > "$GIT_PUSH_LOG"; : > "$DOTAGENTS_LOG"
}
gh_call_count() { grep -c '^pr ' "$GH_LOG" 2>/dev/null || true; }

# =========================================================================
# Case 1: WORKSPACE is not a git repo -> one line, exit 0, install never run.
# =========================================================================
NON_REPO="$TMP/not-a-repo"
mkdir -p "$NON_REPO"
set +e
OUT="$(WORKSPACE="$NON_REPO" TOOLDIR="$STUB_DIR" PROJECT_NAME=proj GH_OWNER=owner \
  GITHUB_APP_DIR="$GITHUB_APP_DIR" DOTAGENTS_LOG="$DOTAGENTS_LOG" TOKEN_LOG="$TOKEN_LOG" PATH="$STUB_PATH" \
  bash "$TEST_SCRIPT" 2>&1)"
STATUS=$?
set -e
[[ $STATUS -eq 0 ]] || fail "case 1: exited $STATUS, expected 0: $OUT"
[[ ! -s $DOTAGENTS_LOG ]] || fail "case 1: dotagents-install.sh was invoked on a non-repo WORKSPACE"
[[ "$OUT" == *"not a git repository"* ]] || fail "case 1: expected an explanatory line, got: $OUT"

# =========================================================================
# Case 2: dotagents-install.sh missing at TOOLDIR -> one line, exit 0.
# =========================================================================
EMPTY_TOOLDIR="$TMP/empty-tooldir"
mkdir -p "$EMPTY_TOOLDIR"
reset_workspace
set +e
OUT="$(WORKSPACE="$WORKSPACE_DIR" TOOLDIR="$EMPTY_TOOLDIR" PROJECT_NAME=proj GH_OWNER=owner \
  GITHUB_APP_DIR="$GITHUB_APP_DIR" TOKEN_LOG="$TOKEN_LOG" PATH="$STUB_PATH" bash "$TEST_SCRIPT" 2>&1)"
STATUS=$?
set -e
[[ $STATUS -eq 0 ]] || fail "case 2: exited $STATUS, expected 0: $OUT"
[[ "$OUT" == *"dotagents-install.sh"*"not found"* ]] || fail "case 2: expected a not-found line, got: $OUT"

# =========================================================================
# Case 3: dotagents-install.sh hangs past a bounded timeout -> WARNING
# mentions the timeout, exit 0. REFRESH_SKILLS_TIMEOUT overrides the
# production 120s bound so the test stays fast.
# =========================================================================
reset_workspace
run SLEEP_SECS=2 REFRESH_SKILLS_TIMEOUT=1
[[ $STATUS -eq 0 ]] || fail "case 3: exited $STATUS, expected 0: $OUT"
[[ "$OUT" == *"timed out"* ]] || fail "case 3: expected a timeout warning, got: $OUT"

# =========================================================================
# Case 4: dotagents-install.sh fails outright -> WARNING, exit 0, no bump.
# =========================================================================
reset_workspace
run INSTALL_FAILS=1
[[ $STATUS -eq 0 ]] || fail "case 4: exited $STATUS, expected 0: $OUT"
[[ "$OUT" == *"WARNING"* ]] || fail "case 4: expected a WARNING, got: $OUT"
[[ "$(gh_call_count)" -eq 0 ]] || fail "case 4: gh was called despite install failing"

# =========================================================================
# Case 5: install succeeds, agents.lock unchanged -> no worktree/push/gh
# calls at all, and no WARNING.
# =========================================================================
reset_workspace
run
[[ $STATUS -eq 0 ]] || fail "case 5: exited $STATUS, expected 0: $OUT"
[[ -s $DOTAGENTS_LOG ]] || fail "case 5: dotagents-install.sh was never invoked"
[[ "$(gh_call_count)" -eq 0 ]] || fail "case 5: gh was called despite no agents.lock diff"
[[ "$OUT" != *WARNING* ]] || fail "case 5: unexpected WARNING with no diff: $OUT"

# =========================================================================
# Case 6: install produces a diff, on main, no existing open PR -> gh pr
# create is called once with the fixed branch; agents.lock ends up restored
# to its tracked content.
# =========================================================================
reset_workspace
run NEW_LOCK_CONTENT=new-lock-v1
[[ $STATUS -eq 0 ]] || fail "case 6: exited $STATUS, expected 0: $OUT"
grep -Fq 'pr list' "$GH_LOG" || fail "case 6: expected a gh pr list existing-PR check: $(cat "$GH_LOG")"
grep -Fq 'pr create' "$GH_LOG" || fail "case 6: expected gh pr create to run: $(cat "$GH_LOG")"
grep -Fq -- '--head agent/agents-lock-upgrade' "$GH_LOG" || \
  fail "case 6: expected the fixed bump branch name: $(cat "$GH_LOG")"
[[ "$(wc -l < "$TOKEN_LOG")" -eq 2 ]] || \
  fail "case 6: expected one token mint per gh call: $(cat "$TOKEN_LOG")"
[[ "$OUT" == *"https://github.com/fake/repo/pull/999"* ]] || fail "case 6: expected the PR URL reported: $OUT"
[[ "$(cat "$WORKSPACE_DIR/agents.lock")" == "old-lock" ]] || \
  fail "case 6: primary agents.lock was not restored: $(cat "$WORKSPACE_DIR/agents.lock")"
[[ -z "$(git -C "$WORKSPACE_DIR" status --porcelain)" ]] || \
  fail "case 6: primary worktree left dirty: $(git -C "$WORKSPACE_DIR" status --porcelain)"

# =========================================================================
# Case 7: same, but a PR is already open for the fixed branch -> gh pr
# create is NOT called; the branch is still force-pushed with new content.
# =========================================================================
reset_workspace
run NEW_LOCK_CONTENT=new-lock-v2 EXISTING_PR_URL=https://github.com/fake/repo/pull/42
[[ $STATUS -eq 0 ]] || fail "case 7: exited $STATUS, expected 0: $OUT"
grep -Fq 'pr list' "$GH_LOG" || fail "case 7: expected a gh pr list check: $(cat "$GH_LOG")"
grep -Fq 'pr create' "$GH_LOG" && fail "case 7: gh pr create should not run when a PR is already open: $(cat "$GH_LOG")"
[[ "$(wc -l < "$TOKEN_LOG")" -eq 1 ]] || \
  fail "case 7: expected one token mint for the gh pr list: $(cat "$TOKEN_LOG")"
[[ -s $GIT_PUSH_LOG ]] || fail "case 7: expected the bump branch to still be pushed"
[[ "$OUT" == *"https://github.com/fake/repo/pull/42"* ]] || fail "case 7: expected the existing PR URL reported: $OUT"
[[ "$(cat "$WORKSPACE_DIR/agents.lock")" == "old-lock" ]] || \
  fail "case 7: primary agents.lock was not restored"

# =========================================================================
# Case 8: not on main -> entire bump block skipped, agents.lock left dirty
# (user's own in-progress state), no gh calls, no WARNING.
# =========================================================================
reset_workspace
git -C "$WORKSPACE_DIR" checkout -qb feature
run NEW_LOCK_CONTENT=new-lock-v3
[[ $STATUS -eq 0 ]] || fail "case 8: exited $STATUS, expected 0: $OUT"
[[ "$(gh_call_count)" -eq 0 ]] || fail "case 8: gh was called on a non-main branch: $(cat "$GH_LOG")"
[[ "$(cat "$WORKSPACE_DIR/agents.lock")" == "new-lock-v3" ]] || \
  fail "case 8: agents.lock should have been left as the feature branch's own state"
[[ "$OUT" != *WARNING* ]] || fail "case 8: unexpected WARNING on a non-main branch: $OUT"
git -C "$WORKSPACE_DIR" checkout -q main

# =========================================================================
# Case 9: git push fails -> "auto-PR failed" WARNING, agents.lock still
# restored, gh pr create never reached.
# =========================================================================
reset_workspace
run NEW_LOCK_CONTENT=new-lock-v4 GIT_PUSH_FAILS=1
[[ $STATUS -eq 0 ]] || fail "case 9: exited $STATUS, expected 0: $OUT"
[[ "$OUT" == *"auto-PR failed"* ]] || fail "case 9: expected an auto-PR-failed warning, got: $OUT"
grep -Fq 'pr create' "$GH_LOG" && fail "case 9: gh pr create should not run after a failed push: $(cat "$GH_LOG")"
[[ "$(cat "$WORKSPACE_DIR/agents.lock")" == "old-lock" ]] || \
  fail "case 9: primary agents.lock was not restored after a failed push"

echo "PASS: refresh-skills.test.sh"
