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
# Route the production GitHub URL to a local repository while recording clone
# versus fetch. This exercises a real Git object cache without network access.
cat >"$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = clone ]; then
  printf 'clone\n' >> "$GIT_CALLS"
  [ -z "${CLONE_FAILS:-}" ] || { echo "fatal: could not read from remote" >&2; exit 128; }
  exec /usr/bin/git clone --bare "$FAKE_UPSTREAM" "${@: -1}"
fi
if [ "${1:-}" = -C ] && [ "${3:-}" = fetch ]; then
  printf 'fetch\n' >> "$GIT_CALLS"
  [ -z "${FETCH_FAILS:-}" ] || { echo "fatal: could not read from remote" >&2; exit 128; }
fi
exec /usr/bin/git "$@"
EOF
chmod +x "$TMP/bin/claude" "$TMP/bin/codex" "$TMP/bin/git"
export PATH="$TMP/bin:$PATH"
export CLAUDE_CALLS="$TMP/claude-calls" CODEX_CALLS="$TMP/codex-calls" GIT_CALLS="$TMP/git-calls"
export HOME="$TMP/home"
SP_DIR="$HOME/.codex/marketplaces/superpowers-curated"
CACHE_DIR="$HOME/.codex/cache/openai-plugins.git"

export FAKE_UPSTREAM="$TMP/upstream"
mkdir -p "$FAKE_UPSTREAM/plugins/superpowers/skills/fresh"
echo "fresh skill" >"$FAKE_UPSTREAM/plugins/superpowers/skills/fresh/SKILL.md"
git -C "$FAKE_UPSTREAM" init -q -b main
git -C "$FAKE_UPSTREAM" config user.email test@example.com
git -C "$FAKE_UPSTREAM" config user.name Test
git -C "$FAKE_UPSTREAM" add .
git -C "$FAKE_UPSTREAM" commit -qm initial

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

# --- Codex: first run seeds cache and replaces stale content wholesale ---
seed_stale_install
: >"$CODEX_CALLS"; : >"$GIT_CALLS"
run codex_section
[ "$STATUS" -eq 0 ] || fail "Codex section exited $STATUS ($OUT)"
[ -f "$SP_DIR/plugins/superpowers/skills/fresh/SKILL.md" ] \
  || fail "Codex marketplace was not refreshed from upstream ($OUT)"
[ ! -e "$SP_DIR/plugins/superpowers/skills/removed-upstream" ] \
  || fail "content deleted upstream survived the refresh"
[ ! -e "$SP_DIR.staged" ] || fail "staging directory was left behind"
[ ! -e "$SP_DIR.backup" ] || fail "backup directory was left behind"
jq -e '.plugins[0].name == "superpowers"' "$SP_DIR/.agents/plugins/marketplace.json" >/dev/null \
  || fail "marketplace manifest was not rewritten"
grep -Fxq "plugin marketplace add $SP_DIR" "$CODEX_CALLS" \
  || fail "Codex section never re-read the refreshed marketplace ($(cat "$CODEX_CALLS"))"
grep -Fxq 'plugin add superpowers@superpowers-curated' "$CODEX_CALLS" \
  || fail "Codex section never reinstalled the plugin ($(cat "$CODEX_CALLS"))"
grep -Fq 'superpowers (Codex): 9.9.9' <<<"$OUT" \
  || fail "Codex version was not reported ($OUT)"
[ -d "$CACHE_DIR" ] || fail "Codex source cache was not persisted under ~/.codex"
[ "$(grep -c '^clone$' "$GIT_CALLS")" -eq 1 ] || fail "first refresh did not clone exactly once"

# --- Codex: unchanged source fetches against cache without recloning or rematerializing ---
echo "local reuse proof" > "$SP_DIR/local-reuse-proof"
# Move upstream HEAD without changing the Superpowers subtree. Comparing its
# Git tree object, rather than the repository commit, must still reuse live data.
echo "unrelated plugin change" > "$FAKE_UPSTREAM/README.md"
git -C "$FAKE_UPSTREAM" add README.md
git -C "$FAKE_UPSTREAM" commit -qm unrelated
run codex_section
[ "$STATUS" -eq 0 ] || fail "second Codex run exited $STATUS ($OUT)"
[ -f "$SP_DIR/local-reuse-proof" ] || fail "unchanged source was rematerialized instead of reused"
[ "$(grep -c '^clone$' "$GIT_CALLS")" -eq 1 ] || fail "unchanged source triggered another full clone"
[ "$(grep -c '^fetch$' "$GIT_CALLS")" -eq 1 ] || fail "unchanged source did not perform one freshness fetch"

# --- Codex: changed source refreshes and upstream removals do not linger ---
rm "$FAKE_UPSTREAM/plugins/superpowers/skills/fresh/SKILL.md"
rmdir "$FAKE_UPSTREAM/plugins/superpowers/skills/fresh"
mkdir -p "$FAKE_UPSTREAM/plugins/superpowers/skills/updated"
echo "updated skill" > "$FAKE_UPSTREAM/plugins/superpowers/skills/updated/SKILL.md"
git -C "$FAKE_UPSTREAM" add -A
git -C "$FAKE_UPSTREAM" commit -qm update
run codex_section
[ "$STATUS" -eq 0 ] || fail "changed Codex refresh exited $STATUS ($OUT)"
[ -f "$SP_DIR/plugins/superpowers/skills/updated/SKILL.md" ] || fail "changed source was not materialized"
[ ! -e "$SP_DIR/plugins/superpowers/skills/fresh" ] || fail "removed upstream content lingered"
[ ! -e "$SP_DIR/local-reuse-proof" ] || fail "changed source did not replace old tree"
[ "$(grep -c '^clone$' "$GIT_CALLS")" -eq 1 ] || fail "changed source recloned instead of fetching"

# --- Codex: failed fetch preserves live content and a later run retries ---
mkdir -p "$FAKE_UPSTREAM/plugins/superpowers/skills/retried"
echo "retried skill" > "$FAKE_UPSTREAM/plugins/superpowers/skills/retried/SKILL.md"
git -C "$FAKE_UPSTREAM" add .
git -C "$FAKE_UPSTREAM" commit -qm retry
FETCH_FAILS=1 run codex_section
[ "$STATUS" -eq 0 ] || fail "failed fetch aborted setup (exit $STATUS): $OUT"
grep -Fq 'WARNING: failed to refresh openai/plugins' <<<"$OUT" \
  || fail "failed fetch was not reported ($OUT)"
[ -f "$SP_DIR/plugins/superpowers/skills/updated/SKILL.md" ] \
  || fail "failed fetch destroyed the existing Codex copy"
[ ! -e "$SP_DIR/plugins/superpowers/skills/retried" ] || fail "failed fetch used partial source state"
[ ! -e "$SP_DIR.staged" ] || fail "failed fetch left a marketplace staging directory"
grep -Fq 'superpowers (Codex): ' <<<"$OUT" \
  || fail "version line went missing on the failure path ($OUT)"
run codex_section
[ "$STATUS" -eq 0 ] || fail "retry after failed fetch exited $STATUS ($OUT)"
[ -f "$SP_DIR/plugins/superpowers/skills/retried/SKILL.md" ] || fail "later setup did not retry failed fetch"

echo "PASS: superpowers-refresh.test.sh"
