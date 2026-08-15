#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/.devcontainer/worktree-warden-summary.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$SCRIPT" ]] || fail "worktree-warden-summary.sh missing at $SCRIPT"

# Helper: source the script and call worktree_warden_summary against DIR in a
# fresh subshell, optionally under strict mode, capturing stdout+exit status.
# A trailing "echo MARKER_OK" proves the caller's shell is still alive after
# the call (relevant for the corrupt-JSON case).
run_summary() {
  local dir="$1" strict="${2:-}"
  local prelude=""
  [[ "$strict" == "strict" ]] && prelude="set -euo pipefail;"
  bash -c "$prelude source '$SCRIPT'; worktree_warden_summary '$dir'; echo MARKER_OK"
}

write_state() {
  local repo="$1" json="$2"
  mkdir -p "$repo/.git/worktree-warden"
  printf '%s' "$json" > "$repo/.git/worktree-warden/state.json"
}

# --- sanity: a fresh `git init` really does resolve --git-common-dir to .git ---
SANITY="$TMP/sanity-repo"
mkdir -p "$SANITY"
git -C "$SANITY" init -q
common="$(git -C "$SANITY" rev-parse --git-common-dir)"
case "$common" in
  /*) ;;
  *) common="$SANITY/$common" ;;
esac
[[ "$common" == "$SANITY/.git" ]] || fail "sanity: git-common-dir resolved to '$common', expected '$SANITY/.git'"

# --- case 1: not inside a git repo -> no output, returns 0 ---
NOTGIT="$TMP/notgit"
mkdir -p "$NOTGIT"
out="$(run_summary "$NOTGIT")"
status=$?
[[ $status -eq 0 ]] || fail "case1: expected exit 0, got $status"
[[ "$out" == "MARKER_OK" ]] || fail "case1: expected no summary output, got: $out"

# --- case 2: inside a git repo, no state.json -> no output ---
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
out="$(run_summary "$REPO")"
status=$?
[[ $status -eq 0 ]] || fail "case2: expected exit 0, got $status"
[[ "$out" == "MARKER_OK" ]] || fail "case2: expected no summary output, got: $out"

# --- case 3: state.json present but every entry is status:pending -> no output ---
write_state "$REPO" '{
  "agent/1-foo": {"branch":"agent/1-foo","pr":1,"issue":1,"status":"pending","reason":null,"diagnostic":null,"updatedAt":"2026-08-15T00:00:00.000Z"}
}'
out="$(run_summary "$REPO")"
status=$?
[[ $status -eq 0 ]] || fail "case3: expected exit 0, got $status"
[[ "$out" == "MARKER_OK" ]] || fail "case3: expected no summary output, got: $out"

# --- case 4: exactly one non-pending entry -> exactly one matching line ---
write_state "$REPO" '{
  "agent/45-foo": {"branch":"agent/45-foo","pr":123,"issue":45,"status":"blocked","reason":"dirty-worktree","diagnostic":null,"updatedAt":"2026-08-15T00:00:00.000Z"}
}'
out="$(run_summary "$REPO")"
status=$?
[[ $status -eq 0 ]] || fail "case4: expected exit 0, got $status"
expected="Worktree Warden: PR #123 / issue #45 failed — blocked: dirty-worktree
MARKER_OK"
[[ "$out" == "$expected" ]] || fail "case4: unexpected output:
$out
--- expected ---
$expected"

# --- case 5: __runOnce__ daemon-error entry ---
write_state "$REPO" '{
  "__runOnce__": {"branch":"__runOnce__","pr":null,"issue":null,"status":"daemon-error","reason":"token-mint-failed","diagnostic":"boom","updatedAt":"2026-08-15T00:00:00.000Z"}
}'
out="$(run_summary "$REPO")"
status=$?
[[ $status -eq 0 ]] || fail "case5: expected exit 0, got $status"
expected="Worktree Warden: daemon error — daemon-error: token-mint-failed
MARKER_OK"
[[ "$out" == "$expected" ]] || fail "case5: unexpected output:
$out
--- expected ---
$expected"

# --- case 6: multiple non-pending entries -> multiple lines, all present ---
write_state "$REPO" '{
  "agent/1-a": {"branch":"agent/1-a","pr":1,"issue":11,"status":"blocked","reason":"dirty-worktree","diagnostic":null,"updatedAt":"2026-08-15T00:00:00.000Z"},
  "agent/2-b": {"branch":"agent/2-b","pr":2,"issue":22,"status":"retry","reason":"push-failed","diagnostic":null,"updatedAt":"2026-08-15T00:00:00.000Z"},
  "agent/3-c": {"branch":"agent/3-c","pr":3,"issue":33,"status":"pending","reason":null,"diagnostic":null,"updatedAt":"2026-08-15T00:00:00.000Z"},
  "__runOnce__": {"branch":"__runOnce__","pr":null,"issue":null,"status":"daemon-error","reason":"token-mint-failed","diagnostic":null,"updatedAt":"2026-08-15T00:00:00.000Z"}
}'
out="$(run_summary "$REPO")"
status=$?
[[ $status -eq 0 ]] || fail "case6: expected exit 0, got $status"
line_count="$(printf '%s\n' "$out" | grep -c '^Worktree Warden:' || true)"
[[ "$line_count" -eq 3 ]] || fail "case6: expected 3 Worktree Warden lines, got $line_count. Output:
$out"
grep -qF 'Worktree Warden: PR #1 / issue #11 failed — blocked: dirty-worktree' <<<"$out" \
  || fail "case6: missing agent/1-a line. Output:
$out"
grep -qF 'Worktree Warden: PR #2 / issue #22 failed — retry: push-failed' <<<"$out" \
  || fail "case6: missing agent/2-b line. Output:
$out"
grep -qF 'Worktree Warden: daemon error — daemon-error: token-mint-failed' <<<"$out" \
  || fail "case6: missing __runOnce__ line. Output:
$out"
grep -qF 'agent/3-c' <<<"$out" \
  && fail "case6: pending entry agent/3-c must not appear. Output:
$out"

# --- case 7: corrupt JSON -> no output, no crash, current shell survives ---
write_state "$REPO" '{ this is not valid json !!! '
out="$(run_summary "$REPO")"
status=$?
[[ $status -eq 0 ]] || fail "case7: expected exit 0, got $status"
[[ "$out" == "MARKER_OK" ]] || fail "case7: expected no summary output for corrupt JSON, got: $out"
# Same assertion again, but with the caller's shell under strict mode (`set
# -euo pipefail`) to prove sourcing this script can never abort a strict
# caller — this is the concrete failure mode the sourceable-library contract
# guards against.
out_strict="$(run_summary "$REPO" strict)"
status=$?
[[ $status -eq 0 ]] || fail "case7 (strict): expected exit 0, got $status"
[[ "$out_strict" == "MARKER_OK" ]] || fail "case7 (strict): expected no summary output for corrupt JSON, got: $out_strict"

# --- case 8: null reason/pr/issue fall back to unknown/? rather than the
# literal string "null" ---
write_state "$REPO" '{
  "agent/9-bar": {"branch":"agent/9-bar","pr":null,"issue":null,"status":"retry","reason":null,"diagnostic":null,"updatedAt":"2026-08-15T00:00:00.000Z"}
}'
out="$(run_summary "$REPO")"
status=$?
[[ $status -eq 0 ]] || fail "case8: expected exit 0, got $status"
expected="Worktree Warden: PR #? / issue #? failed — retry: unknown
MARKER_OK"
[[ "$out" == "$expected" ]] || fail "case8: unexpected output:
$out
--- expected ---
$expected"
[[ "$out" != *null* ]] || fail "case8: literal 'null' leaked into output: $out"

# --- case 9: "waiting" status (issue #63 names four simulated result kinds
# explicitly: invocation failure, waiting, retry, blocked — cases 4/5/6/8
# already cover blocked/daemon-error/retry; this closes the "waiting" gap) ---
write_state "$REPO" '{
  "agent/7-baz": {"branch":"agent/7-baz","pr":77,"issue":7,"status":"waiting","reason":"ambiguous-pr-issue","diagnostic":null,"updatedAt":"2026-08-15T00:00:00.000Z"}
}'
out="$(run_summary "$REPO")"
status=$?
[[ $status -eq 0 ]] || fail "case9: expected exit 0, got $status"
expected="Worktree Warden: PR #77 / issue #7 failed — waiting: ambiguous-pr-issue
MARKER_OK"
[[ "$out" == "$expected" ]] || fail "case9: unexpected output:
$out
--- expected ---
$expected"

echo "PASS: worktree-warden-summary"
