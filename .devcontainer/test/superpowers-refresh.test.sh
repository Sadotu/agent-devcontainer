#!/usr/bin/env bash
# Exercises setup-agents.sh's Superpowers refresh for Claude and Codex with
# stub CLIs, sourcing the real sections out of the script (same in-place
# technique as setup-auth-bootstrap.test.sh) so no production seam is needed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP="$ROOT/.devcontainer/setup-agents.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- section extraction (fails loudly if a heading or trailer moves) ---
section() {
  local body
  body="$(sed -n "$1,$2 p" "$SETUP")"
  [ -n "$body" ] || fail "section $1 .. $2 is empty — setup-agents.sh anchors are stale"
  printf '%s\n' "$body"
}
claude_section() {
  section '/^echo "==> Claude Code plugins\/skills"$/' '/^echo "    superpowers (Claude): /' \
    | source /dev/stdin
}
codex_section() {
  section '/^echo "==> Codex plugins\/skills"$/' '/^echo "    superpowers (Codex): /' \
    | source /dev/stdin
}
run() {  # run <section-fn>; sets OUT and STATUS, never aborts the suite
  set +e
  OUT="$("$1" 2>&1)"
  STATUS=$?
  set -e
}

# --- stubs ---
mkdir -p "$TMP/bin"
cat >"$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CLAUDE_CALLS"
[ "$*" = "plugin list --json" ] && echo '[{"id":"superpowers@superpowers-marketplace","version":"6.3.0"}]'
exit 0
EOF
cat >"$TMP/bin/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CODEX_CALLS"
[ "$*" = "plugin list --json" ] && \
  echo '{"installed":[{"pluginId":"superpowers@superpowers-curated","version":"9.9.9"}]}'
exit 0
EOF
# `git clone --depth 1 <url> <dest>` — populates <dest> from $FAKE_UPSTREAM,
# or fails like a network error when $CLONE_FAILS is set.
cat >"$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = clone ]; then
  [ -z "${CLONE_FAILS:-}" ] || { echo "fatal: could not read from remote" >&2; exit 128; }
  mkdir -p "${@: -1}"
  cp -r "$FAKE_UPSTREAM/." "${@: -1}/"
  exit 0
fi
exec /usr/bin/git "$@"
EOF
chmod +x "$TMP/bin/claude" "$TMP/bin/codex" "$TMP/bin/git"
export PATH="$TMP/bin:$PATH"
export CLAUDE_CALLS="$TMP/claude-calls" CODEX_CALLS="$TMP/codex-calls"
export HOME="$TMP/home"
SP_DIR="$HOME/.codex/marketplaces/superpowers-curated"

export FAKE_UPSTREAM="$TMP/upstream"
mkdir -p "$FAKE_UPSTREAM/plugins/superpowers/skills/fresh"
echo "fresh skill" >"$FAKE_UPSTREAM/plugins/superpowers/skills/fresh/SKILL.md"

seed_stale_install() {  # an existing, outdated Codex marketplace from a prior rebuild
  rm -rf "$SP_DIR"
  mkdir -p "$SP_DIR/plugins/superpowers/skills/removed-upstream" "$SP_DIR/.agents/plugins"
  echo "stale skill" >"$SP_DIR/plugins/superpowers/skills/removed-upstream/SKILL.md"
  echo '{"name":"superpowers-curated","plugins":[]}' >"$SP_DIR/.agents/plugins/marketplace.json"
}

# --- Claude: re-running setup updates an existing installation ---
: >"$CLAUDE_CALLS"
run claude_section
[ "$STATUS" -eq 0 ] || fail "Claude section exited $STATUS ($OUT)"
grep -Fxq 'plugin marketplace add obra/superpowers-marketplace' "$CLAUDE_CALLS" \
  || fail "Claude section stopped adding the marketplace (update needs it added first)"
grep -Fxq 'plugin marketplace update superpowers-marketplace' "$CLAUDE_CALLS" \
  || fail "Claude section never refreshed the marketplace ($(cat "$CLAUDE_CALLS"))"
grep -Fxq 'plugin update superpowers@superpowers-marketplace' "$CLAUDE_CALLS" \
  || fail "Claude section never updated the installed plugin ($(cat "$CLAUDE_CALLS"))"
grep -Fq 'superpowers (Claude): 6.3.0' <<<"$OUT" \
  || fail "Claude version was not reported ($OUT)"

# --- Codex: re-running setup replaces an existing installation wholesale ---
seed_stale_install
: >"$CODEX_CALLS"
run codex_section
[ "$STATUS" -eq 0 ] || fail "Codex section exited $STATUS ($OUT)"
[ -f "$SP_DIR/plugins/superpowers/skills/fresh/SKILL.md" ] \
  || fail "Codex marketplace was not refreshed from upstream ($OUT)"
[ ! -e "$SP_DIR/plugins/superpowers/skills/removed-upstream" ] \
  || fail "content deleted upstream survived the refresh"
[ ! -e "$SP_DIR.staged" ] || fail "staging directory was left behind"
jq -e '.plugins[0].name == "superpowers"' "$SP_DIR/.agents/plugins/marketplace.json" >/dev/null \
  || fail "marketplace manifest was not rewritten"
grep -Fxq "plugin marketplace add $SP_DIR" "$CODEX_CALLS" \
  || fail "Codex section never re-read the refreshed marketplace ($(cat "$CODEX_CALLS"))"
grep -Fxq 'plugin add superpowers@superpowers-curated' "$CODEX_CALLS" \
  || fail "Codex section never reinstalled the plugin ($(cat "$CODEX_CALLS"))"
grep -Fq 'superpowers (Codex): 9.9.9' <<<"$OUT" \
  || fail "Codex version was not reported ($OUT)"

# --- Codex: a second run is idempotent ---
before="$(find "$SP_DIR" | sort)"
run codex_section
[ "$STATUS" -eq 0 ] || fail "second Codex run exited $STATUS ($OUT)"
[ "$before" = "$(find "$SP_DIR" | sort)" ] || fail "second Codex run changed the tree"

# --- Codex: a failed download keeps the working copy and does not abort ---
seed_stale_install
: >"$CODEX_CALLS"
CLONE_FAILS=1 run codex_section
[ "$STATUS" -eq 0 ] || fail "failed clone aborted setup (exit $STATUS): $OUT"
grep -Fq 'WARNING: failed to clone openai/plugins' <<<"$OUT" \
  || fail "failed clone was not reported ($OUT)"
[ -f "$SP_DIR/plugins/superpowers/skills/removed-upstream/SKILL.md" ] \
  || fail "failed clone destroyed the existing Codex copy"
[ ! -e "$SP_DIR.staged" ] || fail "failed clone left a staging directory behind"
grep -Fq 'superpowers (Codex): ' <<<"$OUT" \
  || fail "version line went missing on the failure path ($OUT)"

echo "PASS: superpowers-refresh.test.sh"
