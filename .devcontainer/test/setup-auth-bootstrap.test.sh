#!/usr/bin/env bash
# Exercises setup-agents.sh's complete credential setup with a fake bw CLI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP="$ROOT/.devcontainer/setup-agents.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Exercise the installed executable in fresh shells, so App auth is independent
# of shell startup files.
GH_TOOLDIR="$TMP/gh-tools"
mkdir -p "$GH_TOOLDIR" "$TMP/bin"

cat >"$GH_TOOLDIR/gh-app-token.sh" <<'EOF'
#!/usr/bin/env bash
printf 'test-app-token\n'
EOF
chmod +x "$GH_TOOLDIR/gh-app-token.sh"

cat >"$TMP/bin/real-gh" <<'EOF'
#!/usr/bin/env bash
printf 'token=%s args=%s\n' "${GH_TOKEN:-}" "$*"
EOF
chmod +x "$TMP/bin/real-gh"

cp "$ROOT/.devcontainer/gh.sh" "$TMP/bin/gh"
sed -i "s|/opt/agent-devcontainer/gh-app-token.sh|$GH_TOOLDIR/gh-app-token.sh|; s|/usr/bin/gh|$TMP/bin/real-gh|" "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"

for shell in bash zsh; do
  OUT="$(PATH="$TMP/bin:$PATH" "$shell" -c 'gh issue list')" \
    || fail "$shell shim invocation failed ($OUT)"
  [ "$OUT" = 'token=test-app-token args=issue list' ] \
    || fail "$shell shim did not pass minted token to real gh ($OUT)"
done

cat >"$GH_TOOLDIR/gh-app-token.sh" <<'EOF'
#!/usr/bin/env bash
echo 'APP TOKEN FAILURE' >&2
exit 23
EOF
chmod +x "$GH_TOOLDIR/gh-app-token.sh"

set +e
OUT="$(PATH="$TMP/bin:$PATH" bash -c 'gh issue list' 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 23 ] || fail "token-helper failure returned $STATUS instead of 23"
grep -Fq 'APP TOKEN FAILURE' <<<"$OUT" || fail "token-helper error was hidden ($OUT)"
! grep -Fq 'token=' <<<"$OUT" || fail "real gh ran after token-helper failure ($OUT)"

mkdir -p "$TMP/bin"
cat >"$TMP/bin/bw" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BW_CALLS"
if [ "${1:-} ${2:-}" = "login --check" ]; then
  exit 1
fi
if [ "${1:-}" = login ]; then
  echo 'VISIBLE LOGIN PROMPT'
  exit 1
fi
echo "unexpected bw call: $*" >&2
exit 9
EOF
chmod +x "$TMP/bin/bw"
export PATH="$TMP/bin:$PATH"
export BW_CALLS="$TMP/bw-calls"
export _SETUP_DIR="$ROOT/.devcontainer"

run_credentials() {
  sed -n '/^echo "==> .*credential setup (Bitwarden)"/,/^bw_relock_if_ours$/p' "$SETUP" \
    | source /dev/stdin
}

grep -Fq 'echo "==> Post-create credential setup (Bitwarden)"' "$SETUP" \
  || fail "credential setup heading is stale"

export HOME="$TMP/persisted-home"
export GITHUB_APP_DIR="$HOME/.config/github-app"
mkdir -p "$GITHUB_APP_DIR" "$HOME/.claude" "$HOME/.codex"
printf '12345\n' >"$GITHUB_APP_DIR/app-id"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
  -out "$GITHUB_APP_DIR/private-key.pem" >/dev/null 2>&1
openssl pkey -noout -in "$GITHUB_APP_DIR/private-key.pem" >/dev/null 2>&1 \
  || fail "persisted App private-key fixture is invalid"
printf 'export CLAUDE_CODE_OAUTH_TOKEN=persisted-token\n' >"$HOME/.claude/oauth-env"
printf '%s\n' '{"tokens":{"refresh_token":"persisted-refresh"}}' >"$HOME/.codex/auth.json"
: >"$BW_CALLS"

OUT="$(run_credentials 2>&1)" || fail "persisted credentials failed setup ($OUT)"
[ ! -s "$BW_CALLS" ] || fail "persisted credentials invoked bw ($(cat "$BW_CALLS"))"
grep -qi 'Codex auth.*present.*usable' <<<"$OUT" \
  || fail "persisted Codex auth was not reported usable ($OUT)"

rm -f "$GITHUB_APP_DIR/app-id" "$GITHUB_APP_DIR/private-key.pem"
: >"$BW_CALLS"
set +e
OUT="$(run_credentials 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -ne 0 ] || fail "missing App credentials unexpectedly succeeded"
grep -Fq 'login --check' "$BW_CALLS" || fail "missing App credentials skipped login check"
grep -Fxq 'login' "$BW_CALLS" || fail "missing App credentials skipped fatal login"
grep -Fq 'VISIBLE LOGIN PROMPT' <<<"$OUT" || fail "login output was not visible ($OUT)"

echo "PASS: setup-auth-bootstrap.test.sh"
