#!/usr/bin/env bash
# Covers #98: setup-agents.sh must disable git's interactive login-prompt
# fallback (GIT_TERMINAL_PROMPT=0) so a failing App credential helper errors
# loudly instead of hanging on a username/password prompt, and must persist
# that to ~/.bashrc idempotently for future interactive shells.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP="$ROOT/.devcontainer/setup-agents.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Wiring: exported before the credential helper section, in-order --------
helper_line="$(grep -n 'git config --global credential.https://github.com.helper' "$SETUP" | head -1 | cut -d: -f1)"
export_line="$(grep -n '^export GIT_TERMINAL_PROMPT=0$' "$SETUP" | head -1 | cut -d: -f1)"
[ -n "$helper_line" ] || fail "credential.helper config line not found"
[ -n "$export_line" ] || fail "setup-agents.sh does not export GIT_TERMINAL_PROMPT=0"
[ "$export_line" -gt "$helper_line" ] || fail "GIT_TERMINAL_PROMPT export is not after the credential helper is wired up"

# --- Wiring: persisted to BASHRC, idempotently, on two runs -----------------
run_bashrc_block() { # <bashrc-path>
  BASHRC="$1" bash -c '
    set -euo pipefail
    BASHRC="$1"
    if ! grep -q "# --- agent-devcontainer no interactive git prompt ---" "$BASHRC"; then
      cat >> "$BASHRC" <<EOF

# --- agent-devcontainer no interactive git prompt ---
export GIT_TERMINAL_PROMPT=0
EOF
    fi
  ' bash "$1"
}

BASHRC="$TMP/.bashrc"
: > "$BASHRC"
run_bashrc_block "$BASHRC"
run_bashrc_block "$BASHRC"
count="$(grep -c '^export GIT_TERMINAL_PROMPT=0$' "$BASHRC")"
[ "$count" -eq 1 ] || fail "expected exactly one GIT_TERMINAL_PROMPT export in .bashrc after two runs, got $count"

# --- Behavior: a failing credential helper errors fast, never hangs ---------
# Simulate the real failure mode (App auth broken) with a helper that always
# declines, against a real (but unreachable) https URL. Without
# GIT_TERMINAL_PROMPT=0, git would block on a login prompt here.
mkdir -p "$TMP/repo"
git -C "$TMP/repo" init -q
export HOME="$TMP/home"
mkdir -p "$HOME"
cat > "$TMP/failing-credential-helper.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TMP/failing-credential-helper.sh"
git -C "$TMP/repo" config credential.helper "!$TMP/failing-credential-helper.sh"

set +e
GIT_TERMINAL_PROMPT=0 timeout 10 \
  git -C "$TMP/repo" fetch https://github.example.invalid/nonexistent/repo.git >"$TMP/out" 2>"$TMP/err"
rc=$?
set -e
[ "$rc" -ne 124 ] || fail "git fetch hung (timed out) instead of failing fast with GIT_TERMINAL_PROMPT=0"
[ "$rc" -ne 0 ] || fail "git fetch against an unreachable/unauthenticated remote unexpectedly succeeded"

echo "PASS: GIT_TERMINAL_PROMPT=0 exported after credential helper wiring, persisted idempotently, git fails fast instead of prompting"
