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
agent_package_section() {
  BASHRC="$HOME/.bashrc"
  section '/^echo "==> Updating agent CLIs to latest/' '/^echo "==> Claude Code plugins\/skills"$/' \
    | sed '$d' \
    | source /dev/stdin
}
codex_section() {
  run_unattended_network() {
    timeout --kill-after="${STARTUP_NETWORK_KILL_AFTER_SECS:-1}" \
      "${STARTUP_NETWORK_TIMEOUT_SECS:-120}" "$@"
  }
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
cat >"$TMP/bin/npm" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *' config set prefix '*) exit 0 ;;
  *' install -g '*|*' install --global '*)
    args="$*"
    prefix="${HOME}/.npm-global"
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --prefix ]; then prefix="$2"; shift 2; continue; fi
      shift
    done
    if [[ "$args" == *'@anthropic-ai/claude-code@latest'* ]]; then
      mkdir -p "$prefix/bin" "$prefix/lib/node_modules/fake"
      printf '#!/usr/bin/env bash\necho new-claude\n' > "$prefix/lib/node_modules/fake/claude"
      chmod +x "$prefix/lib/node_modules/fake/claude"
      ln -sfn ../lib/node_modules/fake/claude "$prefix/bin/claude"
      if [ "${NPM_UPDATE_MODE:-success}" = hang ] && [ ! -e "$NPM_HANG_ONCE" ]; then
        : > "$NPM_HANG_ONCE"
        sleep 30 </dev/null >/dev/null 2>&1 &
        printf '%s\n' "$!" > "$NPM_DESCENDANT_PID"
        sleep 3
      elif [ "${NPM_UPDATE_MODE:-success}" = resist-term ] && [ ! -e "$NPM_HANG_ONCE" ]; then
        : > "$NPM_HANG_ONCE"
        printf '%s\n' "$BASHPID" > "$NPM_DESCENDANT_PID"
        trap '' TERM
        while :; do sleep 1; done
      fi
    fi
    exit "${NPM_INSTALL_STATUS:-0}"
    ;;
  *' list -g '*) printf '%s\n' 'fake@1.0.0'; exit 0 ;;
esac
exit 0
EOF
# `git clone --depth 1 <url> <dest>` — populates <dest> from $FAKE_UPSTREAM,
# or fails like a network error when $CLONE_FAILS is set.
cat >"$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = clone ]; then
  [ -z "${CLONE_FAILS:-}" ] || { echo "fatal: could not read from remote" >&2; exit 128; }
  if [ -n "${CLONE_HANGS:-}" ]; then
    sleep 30 </dev/null >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$CLONE_DESCENDANT_PID"
    sleep 3
  fi
  mkdir -p "${@: -1}"
  cp -r "$FAKE_UPSTREAM/." "${@: -1}/"
  exit 0
fi
exec /usr/bin/git "$@"
EOF
chmod +x "$TMP/bin/claude" "$TMP/bin/codex" "$TMP/bin/git" "$TMP/bin/npm"
export PATH="$TMP/bin:$PATH"
export CLAUDE_CALLS="$TMP/claude-calls" CODEX_CALLS="$TMP/codex-calls"
export HOME="$TMP/home"
SP_DIR="$HOME/.codex/marketplaces/superpowers-curated"
export NPM_HANG_ONCE="$TMP/npm-hang-once" NPM_DESCENDANT_PID="$TMP/npm-descendant-pid"

export FAKE_UPSTREAM="$TMP/upstream"
mkdir -p "$FAKE_UPSTREAM/plugins/superpowers/skills/fresh"
echo "fresh skill" >"$FAKE_UPSTREAM/plugins/superpowers/skills/fresh/SKILL.md"

seed_stale_install() {  # an existing, outdated Codex marketplace from a prior rebuild
  rm -rf "$SP_DIR"
  mkdir -p "$SP_DIR/plugins/superpowers/skills/removed-upstream" "$SP_DIR/.agents/plugins"
  echo "stale skill" >"$SP_DIR/plugins/superpowers/skills/removed-upstream/SKILL.md"
  echo '{"name":"superpowers-curated","plugins":[]}' >"$SP_DIR/.agents/plugins/marketplace.json"
}

seed_prior_npm_install() {
  rm -rf "$HOME/.npm-global" "$HOME/.npm-global.staged" "$HOME/.npm-global.backup"
  mkdir -p "$HOME/.npm-global/bin" "$HOME/.npm-global/lib/node_modules/fake"
  printf '#!/usr/bin/env bash\necho old-claude\n' > "$HOME/.npm-global/lib/node_modules/fake/claude"
  chmod +x "$HOME/.npm-global/lib/node_modules/fake/claude"
  ln -s ../lib/node_modules/fake/claude "$HOME/.npm-global/bin/claude"
}

# --- npm: timeout kills descendants and leaves effective prior install intact ---
seed_prior_npm_install
rm -f "$NPM_HANG_ONCE" "$NPM_DESCENDANT_PID"
STARTUP_NETWORK_TIMEOUT_SECS=1 NPM_UPDATE_MODE=hang run agent_package_section
[ "$STATUS" -eq 0 ] || fail "timed-out optional npm update aborted setup (exit $STATUS): $OUT"
grep -Fq 'timed out after 1s' <<<"$OUT" || fail "npm timeout was not reported ($OUT)"
[ "$("$HOME/.npm-global/bin/claude")" = old-claude ] || fail "npm timeout replaced prior working CLI"
[ "$(readlink "$HOME/.npm-global/bin/claude")" = ../lib/node_modules/fake/claude ] \
  || fail "npm timeout changed prior relative executable link"
[ ! -e "$HOME/.npm-global.staged" ] || fail "npm timeout left staging prefix"
descendant_pid="$(cat "$NPM_DESCENDANT_PID")"
for _ in $(seq 1 50); do
  [ ! -e "/proc/$descendant_pid" ] && break
  sleep 0.02
done
[ ! -e "/proc/$descendant_pid" ] || fail "npm timeout left descendant $descendant_pid running"

# GNU timeout returns 137 when TERM fails and its KILL grace expires. Preserve
# prior install and report that ambiguity separately from npm failure.
seed_prior_npm_install
rm -f "$NPM_HANG_ONCE" "$NPM_DESCENDANT_PID"
STARTUP_NETWORK_TIMEOUT_SECS=1 STARTUP_NETWORK_KILL_AFTER_SECS=0.2 \
  NPM_UPDATE_MODE=resist-term run agent_package_section
[ "$STATUS" -eq 0 ] || fail "force-killed optional npm update aborted setup (exit $STATUS): $OUT"
grep -Fq 'force-killed or exceeded the 1s network deadline' <<<"$OUT" \
  || fail "ambiguous npm status 137 was reported as ordinary failure ($OUT)"
[ "$("$HOME/.npm-global/bin/claude")" = old-claude ] || fail "force-killed npm update replaced prior CLI"
descendant_pid="$(cat "$NPM_DESCENDANT_PID")"
[ ! -e "/proc/$descendant_pid" ] || fail "force-killed npm process $descendant_pid survived"

# --- npm: successful staged update activates complete relative executable ---
seed_prior_npm_install
rm -f "$NPM_HANG_ONCE"
NPM_UPDATE_MODE=success run agent_package_section
[ "$STATUS" -eq 0 ] || fail "successful npm update exited $STATUS: $OUT"
[ "$("$HOME/.npm-global/bin/claude")" = new-claude ] || fail "successful npm update was not activated"
[ "$(readlink "$HOME/.npm-global/bin/claude")" = ../lib/node_modules/fake/claude ] \
  || fail "activated npm executable link is not relative"
[ ! -e "$HOME/.npm-global.staged" ] || fail "successful npm update left staging prefix"
[ ! -e "$HOME/.npm-global.backup" ] || fail "successful npm update left backup prefix"

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

# --- Codex: stalled clone is bounded with descendants and prior copy intact ---
seed_stale_install
export CLONE_DESCENDANT_PID="$TMP/clone-descendant-pid"
STARTUP_NETWORK_TIMEOUT_SECS=1 CLONE_HANGS=1 run codex_section
[ "$STATUS" -eq 0 ] || fail "stalled clone aborted setup (exit $STATUS): $OUT"
grep -Fq 'timed out after 1s' <<<"$OUT" || fail "clone timeout was not reported ($OUT)"
[ -f "$SP_DIR/plugins/superpowers/skills/removed-upstream/SKILL.md" ] \
  || fail "clone timeout destroyed prior Codex marketplace"
clone_descendant_pid="$(cat "$CLONE_DESCENDANT_PID")"
for _ in $(seq 1 50); do
  [ ! -e "/proc/$clone_descendant_pid" ] && break
  sleep 0.02
done
[ ! -e "/proc/$clone_descendant_pid" ] || fail "clone timeout left descendant running"

echo "PASS: superpowers-refresh.test.sh"
