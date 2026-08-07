#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$ROOT/.devcontainer/dotagents-install.sh"
SETUP="$ROOT/.devcontainer/setup-agents.sh"
DOCKERFILE="$ROOT/.devcontainer/Dockerfile"
LOCK="$ROOT/agents.lock"
GITIGNORE="$ROOT/.gitignore"
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

assert_file_not_contains() {
  local unexpected="$1" actual="$2"
  grep -Fq -- "$unexpected" "$actual" && fail "$actual contains stale text: $unexpected"
  return 0
}

# Routine setup depends on a committed lock that Git must not ignore.
[[ -f "$LOCK" ]] || fail "$LOCK does not exist"
git -C "$ROOT" ls-files --error-unmatch agents.lock >/dev/null 2>&1 || \
  fail "agents.lock is not tracked"
assert_file_not_contains '/agents.lock' "$GITIGNORE"

# Runtime setup and image build must both integrate the locked installer.
assert_file_contains '$TOOLDIR/dotagents-install.sh "$WORKSPACE" "$TOOLDIR"' "$SETUP"
assert_file_contains 'dotagents-install.sh \' "$DOCKERFILE"
assert_file_contains '/opt/agent-devcontainer/dotagents-install.sh \' "$DOCKERFILE"

# Frozen installation must materialize every locked skill in both agent homes.
mkdir "$TMP/smoke"
cp "$LOCK" "$TMP/smoke/agents.lock"
bash "$HELPER" "$TMP/smoke" "$ROOT/.devcontainer"
assert_file_equals "$ROOT/.devcontainer/agents.toml" "$TMP/smoke/agents.toml"
find "$TMP/smoke" -printf '%y %P -> %l\n' | sort > "$TMP/smoke.paths.first"
find "$TMP/smoke" -type f -exec sha256sum {} \; | \
  sed "s|$TMP/smoke/||" | sort > "$TMP/smoke.files.first"
cp "$TMP/smoke/agents.toml" "$TMP/smoke.agents.toml.first"
cp "$TMP/smoke/agents.lock" "$TMP/smoke.agents.lock.first"
bash "$HELPER" "$TMP/smoke" "$ROOT/.devcontainer"
find "$TMP/smoke" -printf '%y %P -> %l\n' | sort > "$TMP/smoke.paths.second"
find "$TMP/smoke" -type f -exec sha256sum {} \; | \
  sed "s|$TMP/smoke/||" | sort > "$TMP/smoke.files.second"
assert_file_equals "$TMP/smoke.paths.first" "$TMP/smoke.paths.second"
assert_file_equals "$TMP/smoke.files.first" "$TMP/smoke.files.second"
assert_file_equals "$TMP/smoke.agents.toml.first" "$TMP/smoke/agents.toml"
assert_file_equals "$TMP/smoke.agents.lock.first" "$TMP/smoke/agents.lock"
for agent_home in .claude .agents; do
  for skill in github-issue review-pr; do
    skill_dir="$TMP/smoke/$agent_home/skills/$skill"
    [[ -f "$skill_dir/SKILL.md" ]] || \
      fail "$agent_home $skill SKILL.md was not installed"
    [[ $skill == github-issue ]] && required_script=isolate.sh || \
      required_script=publish-review.sh
    [[ -f "$skill_dir/scripts/$required_script" ]] || \
      fail "$agent_home $skill $required_script was not installed"
  done
done
assert_file_contains 'review-pr:v1' \
  "$TMP/smoke/.claude/skills/review-pr/scripts/lib/marker.sh"
assert_file_contains 'review-pr:v1' \
  "$TMP/smoke/.agents/skills/review-pr/scripts/lib/marker.sh"

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

# A fresh clone seeded with repository config and lock must remain byte-clean
# after routine setup.
mkdir "$TMP/clean-project"
cp "$ROOT/.devcontainer/agents.toml" "$TMP/clean-project/agents.toml"
cp "$LOCK" "$TMP/clean-project/agents.lock"
cp "$LOCK" "$TMP/clean-project/agents.lock.expected"
git -C "$TMP/clean-project" init -q
git -C "$TMP/clean-project" add agents.toml agents.lock agents.lock.expected
git -C "$TMP/clean-project" -c user.name=Test -c user.email=test@example.invalid \
  commit -qm 'Seed locked project'
DOTAGENTS_CALL_LOG="$TMP/clean-project.calls.log" PATH="$TMP/bin:$PATH" \
  bash "$HELPER" "$TMP/clean-project" "$ROOT/.devcontainer"
printf '%s\n' '-y @sentry/dotagents@1.17.0 install --frozen' > \
  "$TMP/clean-project.calls.expected"
assert_file_equals "$TMP/clean-project.calls.expected" "$TMP/clean-project.calls.log"
assert_file_equals "$TMP/clean-project/agents.lock.expected" "$TMP/clean-project/agents.lock"
[[ -z "$(git -C "$TMP/clean-project" status --porcelain)" ]] || \
  fail "routine install dirtied clean project"

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
