#!/usr/bin/env bash
# Covers `dc`'s configuration-drift handling on a consumer project:
# drift of the project's `dc` against the canonical baked template (the
# passive warning on `up`, and the `self-update` subcommand), and drift of
# the project's devcontainer.json against the required worktree-warden
# `postStartCommand` lifecycle hook (auto-migrated on `up`).
#
# Runs the real `dc` inside a throwaway fake project (image-based
# devcontainer.json) with `docker`/`devcontainer` stubbed on PATH. The stub's
# `docker run --rm <image> cat <template>` emits whatever FAKE_CANONICAL points
# at, so a test controls whether the local copy is in sync, drifted, or the
# image lacks the template (empty file).
set -euo pipefail

REAL_DC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/dc"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

PROJ="$TMP/proj"
PROJ_DC="$PROJ/.devcontainer/dc"
mkdir -p "$PROJ/.devcontainer"

# Canonical content the fake image serves. Default: a pristine copy of dc.
PRISTINE="$TMP/pristine-dc"
cp "$REAL_DC" "$PRISTINE"
export FAKE_CANONICAL="$PRISTINE"

reset_proj() { # <image-based|build-based>
  cp "$REAL_DC" "$PROJ_DC"
  chmod +x "$PROJ_DC"
  rm -f "$PROJ/.devcontainer/dc.bak"
  if [ "${1:-image-based}" = build-based ]; then
    cat >"$PROJ/.devcontainer/devcontainer.json" <<'EOF'
{ "build": { "dockerfile": "Dockerfile" } }
EOF
  else
    cat >"$PROJ/.devcontainer/devcontainer.json" <<'EOF'
{
  "image": "fake/img:latest",
  "postCreateCommand": "/opt/agent-devcontainer/setup-agents.sh",
  "postStartCommand": "/opt/agent-devcontainer/start-worktree-warden.sh"
}
EOF
  fi
}

# --- Stubs -------------------------------------------------------------------
mkdir -p "$TMP/bin"
: >"$TMP/docker.sock"
export DC_DOCKER_SOCK="$TMP/docker.sock"
FAKE_SOCK_GID="$(stat -c '%g' "$DC_DOCKER_SOCK")"
export FAKE_SOCK_GID
export FAKE_HEALTH_CMD="node -e 'fetch(\"http://127.0.0.1:4317/health\").then(response => { if (!response.ok) throw new Error(\"health check failed: \" + response.status); })'"

cat >"$TMP/bin/devcontainer" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-}" in
  ps|pull|network) exit 0 ;;
  run)
    if [ "${2:-}" = "--rm" ]; then
      cat "$FAKE_CANONICAL"   # empty file => image has no baked template
    fi
    exit 0
    ;;
  container)
    fmt="${5:-}"
    [ -n "$fmt" ] || exit 0   # bare `container inspect` existence probe
    case "$fmt" in
      *State.Status*) echo running ;;
      *State.Health.Status*) echo healthy ;;
      *Config.Image*) echo ghcr.io/sadotu/usage-sentinel:latest ;;
      *RestartPolicy.Name*) echo unless-stopped ;;
      *GroupAdd*) echo "$FAKE_SOCK_GID" ;;
      *NetworkSettings.Networks*) echo agent-services ;;
      *Config.Env*)
        cat <<'ENV'
USAGE_SENTINEL_HOST=0.0.0.0
USAGE_SENTINEL_DATA_DIR=/var/lib/usage-sentinel/data
USAGE_SENTINEL_CLAUDE_MANAGED_REFRESH=true
USAGE_SENTINEL_CODEX_MANAGED_REFRESH=true
CLAUDE_CONFIG_DIR=/var/lib/usage-sentinel/claude
CODEX_HOME=/var/lib/usage-sentinel/codex
ENV
        ;;
      *bind*) printf '%s\n' /var/run/docker.sock ;;
      *Mounts*)
        printf '%s\n' \
          'usage-sentinel-data:/var/lib/usage-sentinel/data' \
          'usage-sentinel-claude:/var/lib/usage-sentinel/claude' \
          'usage-sentinel-codex:/var/lib/usage-sentinel/codex'
        ;;
      *Healthcheck.Test*) printf 'CMD-SHELL\n%s' "$FAKE_HEALTH_CMD" ;;
      *Healthcheck.Interval*) echo 30s ;;
      *Healthcheck.Timeout*) echo 5s ;;
      *Healthcheck.Retries*) echo 3 ;;
      *Healthcheck.StartPeriod*) echo 10s ;;
    esac
    ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/docker" "$TMP/bin/devcontainer"
export PATH="$TMP/bin:$PATH"

run_dc() { # <subcommand...> -> sets RC, OUT, ERR
  set +e
  "$PROJ_DC" "$@" >"$TMP/out" 2>"$TMP/err"
  RC=$?
  set -e
  OUT="$(cat "$TMP/out")"; ERR="$(cat "$TMP/err")"
}

# --- self-update: already in sync -------------------------------------------
reset_proj image-based
export FAKE_CANONICAL="$PROJ_DC"          # canonical == local
run_dc self-update
[ "$RC" -eq 0 ] || fail "self-update in-sync exited $RC"
echo "$OUT" | grep -qi 'already matches' || fail "in-sync did not report already-matching"
[ ! -e "$PROJ/.devcontainer/dc.bak" ] || fail "in-sync wrote a needless dc.bak"
export FAKE_CANONICAL="$PRISTINE"

# --- self-update: drifted -> synced, backup kept ----------------------------
reset_proj image-based
printf '\n# local drift marker\n' >>"$PROJ_DC"
cmp -s "$PROJ_DC" "$PRISTINE" && fail "test setup: proj dc should differ"
run_dc self-update
[ "$RC" -eq 0 ] || fail "self-update drifted exited $RC: $ERR"
cmp -s "$PROJ_DC" "$PRISTINE" || fail "self-update did not restore canonical content"
[ -e "$PROJ/.devcontainer/dc.bak" ] || fail "self-update kept no dc.bak"
grep -q 'local drift marker' "$PROJ/.devcontainer/dc.bak" || fail "dc.bak is not the pre-update copy"
[ -x "$PROJ_DC" ] || fail "self-update dropped the exec bit"

# --- self-update: image has no baked template -------------------------------
reset_proj image-based
EMPTY="$TMP/empty"; : >"$EMPTY"
export FAKE_CANONICAL="$EMPTY"
run_dc self-update
[ "$RC" -ne 0 ] || fail "self-update accepted an image with no template"
echo "$ERR" | grep -qi 'template' || fail "no-template error unclear"
cmp -s "$PROJ_DC" "$PRISTINE" || fail "no-template run mutated dc"
export FAKE_CANONICAL="$PRISTINE"

# --- self-update: build-based devcontainer.json (no image key) --------------
reset_proj build-based
run_dc self-update
[ "$RC" -ne 0 ] || fail "self-update accepted a build-based project"
echo "$ERR" | grep -qi 'image' || fail "no-image error unclear"

# --- up: drift warning ------------------------------------------------------
reset_proj image-based
printf '\n# local drift marker\n' >>"$PROJ_DC"
run_dc up
[ "$RC" -eq 0 ] || fail "up should not fail on drift (exit $RC): $ERR"
echo "$ERR" | grep -qi 'self-update' || fail "up did not warn about drift / self-update"

# --- up: in sync, no warning ------------------------------------------------
reset_proj image-based
export FAKE_CANONICAL="$PROJ_DC"
run_dc up
[ "$RC" -eq 0 ] || fail "up in-sync failed (exit $RC): $ERR"
echo "$ERR" | grep -qi 'self-update' && fail "up warned about drift when in sync"
export FAKE_CANONICAL="$PRISTINE"

# --- up: worktree-warden postStartCommand hook ------------------------------
# A project scaffolded before the hook existed keeps a devcontainer.json
# without it, so a newer image installs worktree-warden but nothing runs it.
DEVJSON="$PROJ/.devcontainer/devcontainer.json"
HOOK='"postStartCommand": "/opt/agent-devcontainer/start-worktree-warden.sh"'

valid_json() { python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1"; }

# stale consumer: hook added, existing keys and validity preserved
reset_proj image-based
cat >"$DEVJSON" <<'EOF'
{
  "image": "fake/img:latest",
  "postCreateCommand": "/opt/agent-devcontainer/setup-agents.sh",
  "remoteUser": "vscode"
}
EOF
run_dc up
[ "$RC" -eq 0 ] || fail "up on a stale consumer exited $RC: $ERR"
grep -Fq "$HOOK" "$DEVJSON" || fail "up did not add the hook to a stale consumer"
valid_json "$DEVJSON" || fail "migrated devcontainer.json is not valid JSON"
grep -q '"remoteUser"' "$DEVJSON" || fail "migration dropped an existing key"
printf '%s\n%s\n' "$OUT" "$ERR" | grep -q 'postStartCommand' || fail "migration was silent"

# ...and re-running up is a no-op, not a second hook
before="$(cat "$DEVJSON")"
run_dc up
[ "$(cat "$DEVJSON")" = "$before" ] || fail "second up re-edited an already-migrated file"
[ "$(grep -c 'postStartCommand' "$DEVJSON")" -eq 1 ] || fail "second up duplicated the hook"

# anchor is the last key: needs a comma appended to it
reset_proj image-based
cat >"$DEVJSON" <<'EOF'
{
  "image": "fake/img:latest",
  "postCreateCommand": "/opt/agent-devcontainer/setup-agents.sh"
}
EOF
run_dc up
[ "$RC" -eq 0 ] || fail "up on a last-key anchor exited $RC: $ERR"
grep -Fq "$HOOK" "$DEVJSON" || fail "up did not add the hook after a last-key anchor"
valid_json "$DEVJSON" || fail "last-key migration produced invalid JSON"

# already-current consumer: untouched, and no hook warning
reset_proj image-based
export FAKE_CANONICAL="$PROJ_DC"
before="$(cat "$DEVJSON")"
run_dc up
[ "$RC" -eq 0 ] || fail "up on a current consumer exited $RC: $ERR"
[ "$(cat "$DEVJSON")" = "$before" ] || fail "up edited an already-current devcontainer.json"
printf '%s\n%s\n' "$OUT" "$ERR" | grep -q 'postStartCommand' && fail "up warned about a current consumer"
export FAKE_CANONICAL="$PRISTINE"

# conflicting postStartCommand: never clobbered, warned instead
reset_proj image-based
cat >"$DEVJSON" <<'EOF'
{
  "image": "fake/img:latest",
  "postCreateCommand": "/opt/agent-devcontainer/setup-agents.sh",
  "postStartCommand": "/opt/local/my-own-hook.sh"
}
EOF
before="$(cat "$DEVJSON")"
run_dc up
[ "$RC" -eq 0 ] || fail "up on a conflicting hook exited $RC: $ERR"
[ "$(cat "$DEVJSON")" = "$before" ] || fail "up clobbered a project's own postStartCommand"
echo "$ERR" | grep -Fq '/opt/agent-devcontainer/start-worktree-warden.sh' || fail "conflict warning omits the required hook"

# no postCreateCommand to anchor to: left alone, warned instead
reset_proj image-based
cat >"$DEVJSON" <<'EOF'
{ "image": "fake/img:latest" }
EOF
before="$(cat "$DEVJSON")"
run_dc up
[ "$RC" -eq 0 ] || fail "up without an anchor exited $RC: $ERR"
[ "$(cat "$DEVJSON")" = "$before" ] || fail "up edited a file with no anchor line"
echo "$ERR" | grep -Fq '/opt/agent-devcontainer/start-worktree-warden.sh' || fail "no-anchor warning omits the required hook"

# anchor shares its line with the closing brace: not safely splittable
reset_proj image-based
cat >"$DEVJSON" <<'EOF'
{ "image": "fake/img:latest", "postCreateCommand": "/opt/agent-devcontainer/setup-agents.sh" }
EOF
before="$(cat "$DEVJSON")"
run_dc up
[ "$RC" -eq 0 ] || fail "up on a single-line config exited $RC: $ERR"
[ "$(cat "$DEVJSON")" = "$before" ] || fail "up edited a single-line config it cannot split safely"
echo "$ERR" | grep -Fq '/opt/agent-devcontainer/start-worktree-warden.sh' || fail "single-line warning omits the required hook"

echo "PASS: dc drift detection + self-update + worktree-warden hook migration"
