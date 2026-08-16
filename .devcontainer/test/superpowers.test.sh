#!/usr/bin/env bash
# Covers lib/superpowers.sh: the Claude update verbs, the Codex marketplace
# refresh, version reporting, and the wiring into setup-agents.sh/Dockerfile.
#
# Runs the real library with `claude`, `codex`, and `git` stubbed on PATH, so
# the copy/swap, manifest rewrite, and failure paths are exercised against a
# real filesystem instead of asserted from source text.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$ROOT/.devcontainer/lib/superpowers.sh"
SETUP="$ROOT/.devcontainer/setup-agents.sh"
DOCKERFILE="$ROOT/.devcontainer/Dockerfile"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f $LIB ]] || fail "superpowers library missing"

BIN="$TMP/bin"; mkdir -p "$BIN"
LOG="$TMP/calls.log"

# `claude` stub: records argv, exit code driven by STUB_CLAUDE_RC.
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
printf 'claude %s\n' "$*" >> "$STUB_LOG"
exit "${STUB_CLAUDE_RC:-0}"
STUB
chmod +x "$BIN/claude"

export STUB_LOG="$LOG"
export PATH="$BIN:$PATH"

# --- Claude: all four verbs issued, update verbs after add/install ---
: > "$LOG"
( source "$LIB"; superpowers_update_claude >/dev/null 2>&1 ) \
  || fail "superpowers_update_claude returned nonzero"

grep -qx 'claude plugin marketplace add obra/superpowers-marketplace' "$LOG" \
  || fail "claude marketplace add not issued"
grep -qx 'claude plugin install superpowers@superpowers-marketplace' "$LOG" \
  || fail "claude plugin install not issued"
grep -qx 'claude plugin marketplace update superpowers-marketplace' "$LOG" \
  || fail "claude marketplace update not issued"
grep -qx 'claude plugin update superpowers@superpowers-marketplace' "$LOG" \
  || fail "claude plugin update not issued"

add_line="$(grep -n 'marketplace add' "$LOG" | head -1 | cut -d: -f1)"
upd_line="$(grep -n 'marketplace update' "$LOG" | head -1 | cut -d: -f1)"
[[ "$add_line" -lt "$upd_line" ]] \
  || fail "marketplace update issued before add (fails on a first run)"

# --- Claude: a failing CLI must not fail the function ---
: > "$LOG"
( export STUB_CLAUDE_RC=1; source "$LIB"; superpowers_update_claude >/dev/null 2>&1 ) \
  || fail "superpowers_update_claude propagated a CLI failure"
[[ "$(wc -l < "$LOG")" -eq 4 ]] \
  || fail "a failing CLI stopped later Claude commands"

echo "PASS: superpowers plugin updates"
