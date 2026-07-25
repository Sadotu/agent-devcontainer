#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$ROOT/.devcontainer/dotagents-install.sh"
SETUP="$ROOT/.devcontainer/setup-agents.sh"
DOCKERFILE="$ROOT/.devcontainer/Dockerfile"
README="$ROOT/README.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_equals() {
  local expected="$1" actual="$2"
  cmp -s "$expected" "$actual" || fail "$actual does not match $expected"
}

assert_file_contains() {
  local expected="$1" actual="$2"
  grep -Fq -- "$expected" "$actual" || fail "$actual does not contain: $expected"
}

# Runtime setup and image build must both integrate the locked installer.
assert_file_contains '$TOOLDIR/dotagents-install.sh "$WORKSPACE" "$TOOLDIR"' "$SETUP"
assert_file_contains 'dotagents-install.sh \' "$DOCKERFILE"
assert_file_contains '/opt/agent-devcontainer/dotagents-install.sh \' "$DOCKERFILE"

# Documentation must distinguish routine frozen installs from explicit upgrades.
assert_file_contains 'Routine setup uses the committed `agents.lock` revisions with a frozen install.' "$README"
assert_file_contains '/opt/agent-devcontainer/dotagents-install.sh --upgrade "$PWD" /opt/agent-devcontainer' "$README"

mkdir -p "$TMP/bin" "$TMP/tool"
printf 'skills = ["default"]\n' > "$TMP/tool/agents.toml"
cat > "$TMP/bin/npx" <<'FAKE_NPX'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$DOTAGENTS_CALL_LOG"
case " $* " in
  *" --frozen "*) ;;
  *) printf 'updated-by-fake-npx\n' > agents.lock ;;
esac
FAKE_NPX
chmod +x "$TMP/bin/npx"

run_helper() {
  local workspace="$1"
  shift
  DOTAGENTS_CALL_LOG="$workspace/calls.log" PATH="$TMP/bin:$PATH" \
    bash "$HELPER" "$@" "$workspace" "$TMP/tool"
}

# Routine setup with a lock must use frozen mode and preserve every lock byte.
mkdir "$TMP/locked"
printf 'lock-byte-1\000lock-byte-2\n' > "$TMP/locked/agents.lock"
cp "$TMP/locked/agents.lock" "$TMP/locked/agents.lock.expected"
run_helper "$TMP/locked"
printf '%s\n' '-y @sentry/dotagents@1.17.0 install --frozen' > "$TMP/locked/calls.expected"
assert_file_equals "$TMP/locked/calls.expected" "$TMP/locked/calls.log"
assert_file_equals "$TMP/locked/agents.lock.expected" "$TMP/locked/agents.lock"
assert_file_equals "$TMP/tool/agents.toml" "$TMP/locked/agents.toml"

# First setup without a lock must use the ordinary pinned install.
mkdir "$TMP/no-lock"
run_helper "$TMP/no-lock"
printf '%s\n' '-y @sentry/dotagents@1.17.0 install' > "$TMP/no-lock/calls.expected"
assert_file_equals "$TMP/no-lock/calls.expected" "$TMP/no-lock/calls.log"
printf 'updated-by-fake-npx\n' > "$TMP/no-lock/lock.expected"
assert_file_equals "$TMP/no-lock/lock.expected" "$TMP/no-lock/agents.lock"

# Explicit upgrade must permit an existing lock to be updated.
mkdir "$TMP/upgrade"
printf 'old-lock\n' > "$TMP/upgrade/agents.lock"
run_helper "$TMP/upgrade" --upgrade
printf '%s\n' '-y @sentry/dotagents@1.17.0 install' > "$TMP/upgrade/calls.expected"
assert_file_equals "$TMP/upgrade/calls.expected" "$TMP/upgrade/calls.log"
printf 'updated-by-fake-npx\n' > "$TMP/upgrade/lock.expected"
assert_file_equals "$TMP/upgrade/lock.expected" "$TMP/upgrade/agents.lock"

echo 'PASS: locked dotagents installation'
