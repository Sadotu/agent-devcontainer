#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DC="$ROOT/.devcontainer/dc"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_log() { grep -F -- "$1" "$LOG" >/dev/null || fail "missing docker call: $1"; }
assert_no_log() { ! grep -F -- "$1" "$LOG" >/dev/null || fail "unexpected docker call: $1"; }

assert_project_sentinel_config() {
  node - "$1" <<'EOF' || fail "invalid project sentinel config: $1"
const fs = require("fs");
const path = process.argv[2];
const config = JSON.parse(fs.readFileSync(path, "utf8"));

if (!config.runArgs?.includes("--network=agent-services")) {
  throw new Error(`${path}: missing --network=agent-services run arg`);
}
if (config.containerEnv?.SENTINEL_URL !== "http://usage-sentinel:4317") {
  throw new Error(`${path}: SENTINEL_URL must equal http://usage-sentinel:4317`);
}

const mountSpecs = [config.workspaceMount, ...(config.mounts ?? [])].filter(Boolean);
for (const mount of mountSpecs) {
  const fields = typeof mount === "string"
    ? Object.fromEntries(mount.split(",").map((field) => field.split("=", 2)))
    : mount;
  const endpoints = [
    fields.source ?? fields.src,
    fields.target ?? fields.dst ?? fields.destination,
  ].filter(Boolean);
  for (const endpoint of endpoints) {
    if (endpoint === "/var/run/docker.sock" ||
        endpoint === "/var/lib/usage-sentinel" ||
        endpoint.startsWith("/var/lib/usage-sentinel/")) {
      throw new Error(`${path}: forbidden mount endpoint ${endpoint}`);
    }
  }
  if (JSON.stringify(mount).toLowerCase().includes("sentinel")) {
    throw new Error(`${path}: forbidden Sentinel credential/cache mount`);
  }
}
EOF
}

assert_project_sentinel_config "$ROOT/.devcontainer/devcontainer.json"
assert_project_sentinel_config "$ROOT/.devcontainer/devcontainer.json.template"

README="$ROOT/README.md"
assert_readme() { grep -F -- "$1" "$README" >/dev/null || fail "README missing: $1"; }

assert_readme './.devcontainer/dc up'
assert_readme './.devcontainer/dc shell'
assert_readme '`start work`'
assert_readme 'does not start issue work or an LLM'
assert_readme 'one machine-wide `usage-sentinel`'
assert_readme 'SENTINEL_URL=http://usage-sentinel:4317'
assert_readme './.devcontainer/dc sentinel-update'
assert_readme 'docker volume rm usage-sentinel-claude'
assert_readme 'docker volume rm usage-sentinel-codex'
assert_readme 'issue-orchestrator'
assert_readme 'invokes `issue-orchestrator` with no arguments'
assert_readme 'No agent starts automatically'
! grep -F -- 'explicit `work` argument to `issue-orchestrator`' "$README" >/dev/null ||
  fail 'README contains stale explicit work argument claim'
assert_readme '## Project worker authentication'
assert_readme 'Claude workers launched by `start work`'
assert_readme '`claude setup-token`'
assert_readme '`CLAUDE_CODE_OAUTH_TOKEN`'
assert_readme '`claude-code-oauth-token`'
assert_readme '`codex-auth-token`'
assert_readme '`codex login --device-auth`'
assert_readme 'project-specific `~/.claude` and `~/.codex` volumes'
assert_readme '[Project worker authentication](#project-worker-authentication)'

node - "$README" <<'EOF' || fail 'README provider login blocks incomplete'
const fs = require('fs');
const readme = fs.readFileSync(process.argv[2], 'utf8');
const blocks = [...readme.matchAll(/```bash\n([\s\S]*?)```/g)]
  .map((match) => match[1].replace(/\\\n\s*/g, ' ').replace(/\s+/g, ' ').trim());
const common = [
  'docker stop usage-sentinel',
  'docker run --rm -it --network agent-services',
  '-v usage-sentinel-data:/var/lib/usage-sentinel/data',
  '-v usage-sentinel-claude:/var/lib/usage-sentinel/claude',
  '-v usage-sentinel-codex:/var/lib/usage-sentinel/codex',
  './.devcontainer/dc up',
];
const providers = [
  ['Claude', '-e CLAUDE_CONFIG_DIR=/var/lib/usage-sentinel/claude', '--entrypoint claude ghcr.io/sadotu/usage-sentinel:latest auth login --claudeai'],
  ['Codex', '-e CODEX_HOME=/var/lib/usage-sentinel/codex', '--entrypoint codex ghcr.io/sadotu/usage-sentinel:latest login --config \'cli_auth_credentials_store="file"\' --device-auth'],
];
for (const [name, ...required] of providers) {
  const block = blocks.find((candidate) => required.every((item) => candidate.includes(item)));
  if (!block || !common.every((item) => block.includes(item))) {
    throw new Error(`${name} provider login must be one complete fenced command block`);
  }
}
EOF

cat >"$TMP/harmless-sentinel-path.json" <<'EOF'
{
  "runArgs": ["--network=agent-services"],
  "containerEnv": {
    "SENTINEL_URL": "http://usage-sentinel:4317",
    "DOCUMENTATION_NOTE": "Sentinel stores service data under /var/lib/usage-sentinel"
  },
  "workspaceMount": "source=${localWorkspaceFolder},target=/workspaces/project,type=bind",
  "mounts": ["source=project-cache,target=/home/vscode/.cache,type=volume"]
}
EOF
assert_project_sentinel_config "$TMP/harmless-sentinel-path.json"

mkdir -p "$TMP/bin"
cat >"$TMP/bin/devcontainer" <<'EOF'
#!/usr/bin/env bash
printf 'devcontainer %s\n' "$*" >>"$FAKE_DOCKER_LOG"
EOF
cat >"$TMP/bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf 'sleep %s\n' "$*" >>"$FAKE_DOCKER_LOG"
EOF
cat >"$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >>"$FAKE_DOCKER_LOG"

case "${1:-} ${2:-}" in
  "network inspect")
    if [ "$FAKE_SCENARIO" = network_race ]; then
      grep -Fq 'docker network create agent-services' "$FAKE_DOCKER_LOG"
    else
      [ "$FAKE_SCENARIO" != missing ]
    fi
    ;;
  "network create") [ "$FAKE_SCENARIO" != network_race ] ;;
  "container inspect")
    if [[ "$FAKE_SCENARIO" = missing || "$FAKE_SCENARIO" = container_race || "$FAKE_SCENARIO" = container_race_starting ]] &&
      ! grep -Fq 'docker run -d --name usage-sentinel' "$FAKE_DOCKER_LOG"; then
      exit 1
    fi
    format="${5:-}"
    case "$format" in
      *State.Status*) [[ "$FAKE_SCENARIO" = stopped || "$FAKE_SCENARIO" = starting_stopped ]] && echo exited || echo running ;;
      *State.Health.Status*)
        if [ "$FAKE_SCENARIO" = unhealthy ]; then
          echo unhealthy
        elif [ "$FAKE_SCENARIO" = starting_stopped ]; then
          echo starting
        elif [ "$FAKE_SCENARIO" = container_race_starting ] &&
          [ "$(grep -c 'State.Health.Status' "$FAKE_DOCKER_LOG")" -eq 1 ]; then
          echo starting
        else
          echo healthy
        fi
        ;;
      *Config.Image*) [ "$FAKE_SCENARIO" = incompatible ] && echo wrong/image || echo ghcr.io/sadotu/usage-sentinel:latest ;;
      *HostConfig.RestartPolicy.Name*) echo unless-stopped ;;
      *NetworkSettings.Networks*)
        echo agent-services
        [ "$FAKE_SCENARIO" != extra_network ] || echo arbitrary-network
        ;;
      *Config.Env*)
        cat <<'ENV'
USAGE_SENTINEL_HOST=0.0.0.0
USAGE_SENTINEL_DATA_DIR=/var/lib/usage-sentinel/data
USAGE_SENTINEL_CLAUDE_MANAGED_REFRESH=true
USAGE_SENTINEL_CODEX_MANAGED_REFRESH=true
CLAUDE_CONFIG_DIR=/var/lib/usage-sentinel/claude
CODEX_HOME=/var/lib/usage-sentinel/codex
ENV
        [ "$FAKE_SCENARIO" != duplicate_env ] || echo 'CODEX_HOME=/tmp/override'
        ;;
      *Mounts*)
        printf '%s\n' \
          'usage-sentinel-data:/var/lib/usage-sentinel/data' \
          'usage-sentinel-claude:/var/lib/usage-sentinel/claude' \
          'usage-sentinel-codex:/var/lib/usage-sentinel/codex'
        [ "$FAKE_SCENARIO" != extra_mount ] || echo 'unexpected-volume:/unexpected'
        ;;
      *Healthcheck.Test*)
        if [ "$FAKE_SCENARIO" = different_health ]; then
          printf 'CMD-SHELL\nnode -e false\n'
        else
          printf 'CMD-SHELL\n%s\n' "$FAKE_HEALTH_CMD"
          [ "$FAKE_SCENARIO" != bad_health ] || echo unexpected
        fi
        ;;
      *Healthcheck.Interval*) echo 30s ;;
      *Healthcheck.Timeout*) echo 5s ;;
      *Healthcheck.Retries*) echo 3 ;;
      *Healthcheck.StartPeriod*) echo 10s ;;
    esac
    ;;
  "inspect --format")
    [ "$FAKE_SCENARIO" != missing ] || exit 1
    ;;
esac
[ "${1:-}" != run ] || [[ "$FAKE_SCENARIO" != container_race && "$FAKE_SCENARIO" != container_race_starting ]]
exit 0
EOF
chmod +x "$TMP/bin/docker" "$TMP/bin/devcontainer" "$TMP/bin/sleep"

export PATH="$TMP/bin:$PATH"
export FAKE_HEALTH_CMD="node -e 'fetch(\"http://127.0.0.1:4317/health\").then(response => { if (!response.ok) throw new Error(\"health check failed: \" + response.status); })'"

run_dc() {
  FAKE_SCENARIO="$1" LOG="$TMP/$1-$2.log" FAKE_DOCKER_LOG="$TMP/$1-$2.log"
  export FAKE_SCENARIO FAKE_DOCKER_LOG
  : >"$LOG"
  set +e
  "$DC" "$2" >"$TMP/out" 2>"$TMP/err"
  RC=$?
  set -e
}

run_dc missing up
[ "$RC" -eq 0 ] || fail "missing sentinel up failed"
assert_log "docker network create agent-services"
assert_log "docker pull ghcr.io/sadotu/usage-sentinel:latest"
assert_log "docker run -d --name usage-sentinel --restart unless-stopped --network agent-services"
assert_log "-e USAGE_SENTINEL_HOST=0.0.0.0"
assert_log "-e USAGE_SENTINEL_DATA_DIR=/var/lib/usage-sentinel/data"
assert_log "-e USAGE_SENTINEL_CLAUDE_MANAGED_REFRESH=true"
assert_log "-e USAGE_SENTINEL_CODEX_MANAGED_REFRESH=true"
assert_log "-e CLAUDE_CONFIG_DIR=/var/lib/usage-sentinel/claude"
assert_log "-e CODEX_HOME=/var/lib/usage-sentinel/codex"
assert_log "-v usage-sentinel-data:/var/lib/usage-sentinel/data"
assert_log "-v usage-sentinel-claude:/var/lib/usage-sentinel/claude"
assert_log "-v usage-sentinel-codex:/var/lib/usage-sentinel/codex"
assert_log "--health-cmd $FAKE_HEALTH_CMD"
assert_log "--health-interval 30s --health-timeout 5s --health-retries 3 --health-start-period 10s"

run_dc healthy up
[ "$RC" -eq 0 ] || fail "healthy sentinel up failed"
assert_no_log "docker start usage-sentinel"
assert_no_log "docker rm"
assert_no_log "docker pull ghcr.io/sadotu/usage-sentinel:latest"

run_dc stopped rebuild
[ "$RC" -eq 0 ] || fail "stopped sentinel rebuild failed"
assert_log "docker start usage-sentinel"
assert_no_log "docker rm"

run_dc unhealthy up
[ "$RC" -ne 0 ] || fail "unhealthy sentinel accepted"
grep -qi unhealthy "$TMP/err" || fail "unhealthy failure unclear"

run_dc incompatible up
[ "$RC" -ne 0 ] || fail "incompatible sentinel accepted"
grep -qi incompatible "$TMP/err" || fail "incompatible failure unclear"
assert_no_log "docker rm"
grep -qi 'remove.*manually' "$TMP/err" || fail "incompatible guidance recommends unusable update path"

for scenario in duplicate_env extra_mount extra_network bad_health different_health; do
  run_dc "$scenario" up
  [ "$RC" -ne 0 ] || fail "$scenario sentinel accepted"
  grep -qi incompatible "$TMP/err" || fail "$scenario failure unclear"
  assert_no_log "docker start usage-sentinel"
  assert_no_log "docker rm"
done

run_dc starting_stopped up
[ "$RC" -ne 0 ] || fail "starting sentinel wait did not time out"
grep -qi 'timed out' "$TMP/err" || fail "bounded wait timeout unclear"
[ "$(grep -c '^sleep 2$' "$LOG")" -eq 30 ] || fail "bounded wait exceeded 30 polls"
assert_no_log "docker rm"

run_dc network_race up
[ "$RC" -eq 0 ] || fail "network creation race not reconciled"
assert_log "docker network create agent-services"

run_dc container_race up
[ "$RC" -eq 0 ] || fail "container creation race not reconciled"
[ "$(grep -c '^docker run -d --name usage-sentinel' "$LOG")" -eq 1 ] || fail "container race created competitor"
assert_no_log "docker rm"

run_dc container_race_starting up
[ "$RC" -eq 0 ] || fail "starting container race winner was not awaited"
[ "$(grep -c 'State.Health.Status' "$LOG")" -eq 2 ] || fail "starting race winner health was not rechecked"
assert_no_log "docker rm"

run_dc healthy sentinel-update
[ "$RC" -eq 0 ] || fail "sentinel-update failed"
assert_log "docker pull ghcr.io/sadotu/usage-sentinel:latest"
assert_log "docker rm -f usage-sentinel"
assert_log "docker run -d --name usage-sentinel"
assert_no_log "docker volume rm"

echo "PASS: dc sentinel lifecycle"
