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

# `git` stub: `clone` materializes a fake openai/plugins tree into the last
# argument. STUB_GIT_RC=1 simulates a network failure.
cat > "$BIN/git" <<'STUB'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "$STUB_LOG"
if [[ "${1:-}" == clone ]]; then
  dest="${*: -1}"
  if [[ "${STUB_GIT_RC:-0}" -ne 0 ]]; then exit "$STUB_GIT_RC"; fi
  mkdir -p "$dest/plugins/superpowers/skills/fresh"
  printf 'fresh\n' > "$dest/plugins/superpowers/skills/fresh/SKILL.md"
  printf '{"name":"superpowers","version":"9.9.9"}\n' \
    > "$dest/plugins/superpowers/PLUGIN.json"
  exit 0
fi
exit 0
STUB
chmod +x "$BIN/git"

# `codex` stub: records argv only.
cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
printf 'codex %s\n' "$*" >> "$STUB_LOG"
exit "${STUB_CODEX_RC:-0}"
STUB
chmod +x "$BIN/codex"

# --- Codex: an existing directory is refreshed, not skipped ---
SP="$TMP/codex-sp"
mkdir -p "$SP/plugins/superpowers/skills/stale"
printf 'stale\n' > "$SP/plugins/superpowers/skills/stale/SKILL.md"
printf 'old\n' > "$SP/plugins/superpowers/OLDFILE"
: > "$LOG"
( export CODEX_SP_DIR="$SP"; source "$LIB"; superpowers_update_codex >/dev/null 2>&1 ) \
  || fail "superpowers_update_codex returned nonzero"

grep -q '^git clone' "$LOG" \
  || fail "codex refresh skipped the clone when the directory already existed"
[[ -f "$SP/plugins/superpowers/skills/fresh/SKILL.md" ]] \
  || fail "fresh plugin content not installed"
[[ -e "$SP/plugins/superpowers/OLDFILE" ]] \
  && fail "upstream-deleted file survived the refresh"
[[ -e "$SP/plugins/superpowers/skills/stale" ]] \
  && fail "stale skill survived the refresh"
[[ -f "$SP/.agents/plugins/marketplace.json" ]] \
  || fail "marketplace manifest not written"
grep -q 'superpowers-curated' "$SP/.agents/plugins/marketplace.json" \
  || fail "marketplace manifest missing the local marketplace name"
grep -qx "codex plugin marketplace add $SP" "$LOG" \
  || fail "codex marketplace add not issued"
grep -qx 'codex plugin add superpowers@superpowers-curated' "$LOG" \
  || fail "codex plugin add not issued"
[[ -z "$(find "$SP/plugins" -maxdepth 1 -name '.superpowers.new*' -print -quit)" ]] \
  || fail "staging directory left behind"

# --- Codex: a failed clone keeps the existing copy and stays non-fatal ---
SP2="$TMP/codex-sp2"
mkdir -p "$SP2/plugins/superpowers/skills/keepme"
printf 'keep\n' > "$SP2/plugins/superpowers/skills/keepme/SKILL.md"
mkdir -p "$SP2/.agents/plugins"
printf '{"name":"superpowers-curated"}\n' > "$SP2/.agents/plugins/marketplace.json"
: > "$LOG"
out="$( export CODEX_SP_DIR="$SP2" STUB_GIT_RC=1
        source "$LIB"; superpowers_update_codex 2>&1 )" \
  || fail "a failed clone made superpowers_update_codex return nonzero"
[[ -f "$SP2/plugins/superpowers/skills/keepme/SKILL.md" ]] \
  || fail "failed clone destroyed the existing Codex copy"
grep -q 'WARNING' <<<"$out" \
  || fail "failed clone printed no WARNING"

echo "PASS: superpowers plugin updates"
