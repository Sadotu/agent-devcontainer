#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$ROOT/.devcontainer/dotagents-install.sh"
REFRESH="$ROOT/.devcontainer/refresh-skills.sh"
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

# Runtime setup (via refresh-skills.sh, called from both postCreate and
# postStart — see issue #92) and image build must both integrate the locked
# installer.
assert_file_contains '"$TOOLDIR/dotagents-install.sh" "$WORKSPACE" "$TOOLDIR"' "$REFRESH"
assert_file_contains 'dotagents-install.sh \' "$DOCKERFILE"
assert_file_contains '/opt/agent-devcontainer/dotagents-install.sh \' "$DOCKERFILE"

# --project must scope the install to the workspace only — an isolated
# DOTAGENTS_HOME must never be created or touched by a project install.
GLOBAL_HOME="$TMP/should-not-exist-home"

# Installation must materialize every locked skill in both agent homes.
mkdir "$TMP/smoke"
cp "$LOCK" "$TMP/smoke/agents.lock"
DOTAGENTS_HOME="$GLOBAL_HOME" bash "$HELPER" "$TMP/smoke" "$ROOT/.devcontainer"
assert_file_equals "$ROOT/.devcontainer/agents.toml" "$TMP/smoke/agents.toml"
find "$TMP/smoke" -printf '%y %P -> %l\n' | sort > "$TMP/smoke.paths.first"
find "$TMP/smoke" -type f -exec sha256sum {} \; | \
  sed "s|$TMP/smoke/||" | sort > "$TMP/smoke.files.first"
cp "$TMP/smoke/agents.toml" "$TMP/smoke.agents.toml.first"
cp "$TMP/smoke/agents.lock" "$TMP/smoke.agents.lock.first"
DOTAGENTS_HOME="$GLOBAL_HOME" bash "$HELPER" "$TMP/smoke" "$ROOT/.devcontainer"
find "$TMP/smoke" -printf '%y %P -> %l\n' | sort > "$TMP/smoke.paths.second"
find "$TMP/smoke" -type f -exec sha256sum {} \; | \
  sed "s|$TMP/smoke/||" | sort > "$TMP/smoke.files.second"
assert_file_equals "$TMP/smoke.paths.first" "$TMP/smoke.paths.second"
assert_file_equals "$TMP/smoke.files.first" "$TMP/smoke.files.second"
assert_file_equals "$TMP/smoke.agents.toml.first" "$TMP/smoke/agents.toml"
assert_file_equals "$TMP/smoke.agents.lock.first" "$TMP/smoke/agents.lock"
[[ -e "$GLOBAL_HOME" ]] && fail "--project install created/touched global DOTAGENTS_HOME: $GLOBAL_HOME"
for agent_home in .claude .agents; do
  for skill in github-issue setup review-pr github-pr-cleanup; do
    skill_dir="$TMP/smoke/$agent_home/skills/$skill"
    [[ -f "$skill_dir/SKILL.md" ]] || \
      fail "$agent_home $skill SKILL.md was not installed"
  done
  [[ -f "$TMP/smoke/$agent_home/skills/github-issue/scripts/isolate.sh" ]] || \
    fail "$agent_home github-issue isolate.sh was not installed"
  [[ -f "$TMP/smoke/$agent_home/skills/review-pr/scripts/publish-review.sh" ]] || \
    fail "$agent_home review-pr publish-review.sh was not installed"
done
assert_file_contains 'review-pr:v1' \
  "$TMP/smoke/.claude/skills/review-pr/scripts/lib/marker.sh"
assert_file_contains 'review-pr:v1' \
  "$TMP/smoke/.agents/skills/review-pr/scripts/lib/marker.sh"

# A project with its own five-skill manifest (the Issue Orchestrator shape)
# must keep that manifest — cp -n must not clobber it with the baked
# four-skill template — install all five including address-review, and leave
# an unrelated project-local skill dir untouched.
mkdir -p "$TMP/orchestrator/.claude/skills/my-local-skill"
echo '# local, not managed by dotagents' > "$TMP/orchestrator/.claude/skills/my-local-skill/SKILL.md"
cat > "$TMP/orchestrator/agents.toml" <<'EOF'
version = 1
agents = ["claude", "codex"]

[[skills]]
name = "github-issue"
source = "Sadotu/agent-skills"

[[skills]]
name = "setup"
source = "Sadotu/agent-skills"

[[skills]]
name = "review-pr"
source = "Sadotu/agent-skills"

[[skills]]
name = "github-pr-cleanup"
source = "Sadotu/agent-skills"

[[skills]]
name = "address-review"
source = "Sadotu/agent-skills"
EOF
cp "$TMP/orchestrator/agents.toml" "$TMP/orchestrator.agents.toml.expected"
bash "$HELPER" "$TMP/orchestrator" "$ROOT/.devcontainer"
assert_file_equals "$TMP/orchestrator.agents.toml.expected" "$TMP/orchestrator/agents.toml"
[[ -f "$TMP/orchestrator/.claude/skills/my-local-skill/SKILL.md" ]] || \
  fail "orchestrator: unrelated project-local skill was lost"
for agent_home in .claude .agents; do
  for skill in github-issue setup review-pr github-pr-cleanup address-review; do
    [[ -f "$TMP/orchestrator/$agent_home/skills/$skill/SKILL.md" ]] || \
      fail "orchestrator: $agent_home $skill was not installed"
  done
done

mkdir -p "$TMP/bin" "$TMP/tool"
printf 'skills = ["default"]\n' > "$TMP/tool/agents.toml"
cat > "$TMP/bin/npx" <<'FAKE_NPX'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$DOTAGENTS_CALL_LOG"
printf 'updated-by-fake-npx\n' > agents.lock
FAKE_NPX
chmod +x "$TMP/bin/npx"

# Routine setup now re-resolves every skill to its source's latest commit on
# every dc up (a stale pin is what let github-issue's Phase 7 script silently
# rot upstream), so a fresh clone's lock is expected to move, not stay
# byte-clean.
mkdir "$TMP/clean-project"
cp "$ROOT/.devcontainer/agents.toml" "$TMP/clean-project/agents.toml"
cp "$LOCK" "$TMP/clean-project/agents.lock"
git -C "$TMP/clean-project" init -q
git -C "$TMP/clean-project" add agents.toml agents.lock
git -C "$TMP/clean-project" -c user.name=Test -c user.email=test@example.invalid \
  commit -qm 'Seed locked project'
DOTAGENTS_CALL_LOG="$TMP/clean-project.calls.log" PATH="$TMP/bin:$PATH" \
  bash "$HELPER" "$TMP/clean-project" "$ROOT/.devcontainer"
printf '%s\n' '-y @sentry/dotagents@3.0.1 --project install' > \
  "$TMP/clean-project.calls.expected"
assert_file_equals "$TMP/clean-project.calls.expected" "$TMP/clean-project.calls.log"
printf 'updated-by-fake-npx\n' > "$TMP/clean-project.agents.lock.expected"
assert_file_equals "$TMP/clean-project.agents.lock.expected" "$TMP/clean-project/agents.lock"

run_helper() {
  local workspace="$1"
  DOTAGENTS_CALL_LOG="$workspace/calls.log" PATH="$TMP/bin:$PATH" \
    bash "$HELPER" "$workspace" "$TMP/tool"
}

# An existing lock must still be re-resolved (no more frozen/no-touch path —
# dotagents 3 dropped --frozen, and the only real caller always re-resolves).
mkdir "$TMP/locked"
printf 'old-lock\n' > "$TMP/locked/agents.lock"
run_helper "$TMP/locked"
printf '%s\n' '-y @sentry/dotagents@3.0.1 --project install' > "$TMP/locked/calls.expected"
assert_file_equals "$TMP/locked/calls.expected" "$TMP/locked/calls.log"
printf 'updated-by-fake-npx\n' > "$TMP/locked/lock.expected"
assert_file_equals "$TMP/locked/lock.expected" "$TMP/locked/agents.lock"
assert_file_equals "$TMP/tool/agents.toml" "$TMP/locked/agents.toml"

# First setup without a lock must use the same project-scoped install.
mkdir "$TMP/no-lock"
run_helper "$TMP/no-lock"
printf '%s\n' '-y @sentry/dotagents@3.0.1 --project install' > "$TMP/no-lock/calls.expected"
assert_file_equals "$TMP/no-lock/calls.expected" "$TMP/no-lock/calls.log"
printf 'updated-by-fake-npx\n' > "$TMP/no-lock/lock.expected"
assert_file_equals "$TMP/no-lock/lock.expected" "$TMP/no-lock/agents.lock"

# A trailing --upgrade argument is no longer accepted — dotagents 3 install
# always re-resolves, so the helper's own upgrade/frozen distinction is gone.
mkdir "$TMP/rejects-upgrade-flag"
if bash "$HELPER" --upgrade "$TMP/rejects-upgrade-flag" "$TMP/tool" >/dev/null 2>&1; then
  fail "helper must reject the retired --upgrade flag"
fi

echo 'PASS: locked dotagents installation'
