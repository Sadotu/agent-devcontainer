#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf 'Usage: %s --source-only | IMAGE_TAG\n' "$0" >&2
    exit 2
}

assert_invalid_usage() {
    local output status

    set +e
    output="$(start "$@" 2>&1)"
    status=$?
    set -e

    [[ $status -ne 0 ]] || {
        printf 'start unexpectedly accepted invalid arguments\n' >&2
        return 1
    }
    [[ $output == 'Usage: start work' ]] || {
        printf 'unexpected usage: %s\n' "$output" >&2
        return 1
    }
}

source_test() {
    local temp_dir status cleanup test_dir devcontainer_dir artifact package_json archive_listing artifact_sha
    local short_commit full_commit pkg_version expected_sha
    local output invocation curl_calls custom_curl_calls
    test_dir="$(cd "$(dirname "$0")" && pwd)"
    devcontainer_dir="$(dirname "$test_dir")"

    # Derived from the Dockerfile itself (not hardcoded) so bumping the
    # vendored issue-orchestrator package can't leave this test asserting a
    # stale commit/hash/version — it was hardcoded once and silently drifted
    # out of sync with the Dockerfile across a later vendor bump.
    short_commit="$(grep -oP '(?<=COPY vendor/issue-orchestrator-)[0-9a-f]+(?=\.tgz)' "$devcontainer_dir/Dockerfile" | head -1)"
    [[ -n $short_commit ]]
    full_commit="$(grep -oP '(?<=# commit )[0-9a-f]+' "$devcontainer_dir/Dockerfile" | head -1)"
    pkg_version="$(grep -oP '(?<=package version )[0-9.]+(?=\)\.)' "$devcontainer_dir/Dockerfile" | head -1)"
    expected_sha="$(grep -oP '(?<=SHA-256 )[0-9a-f]+' "$devcontainer_dir/Dockerfile" | head -1)"
    [[ $full_commit == "$short_commit"* ]]

    artifact="$devcontainer_dir/vendor/issue-orchestrator-$short_commit.tgz"

    [[ -f $artifact ]]
    artifact_sha="$(sha256sum "$artifact")"
    [[ ${artifact_sha%% *} == "$expected_sha" ]]
    archive_listing="$(tar -tzf "$artifact")"
    grep -Fxq 'package/package.json' <<<"$archive_listing"
    grep -Fxq 'package/bin/supervisor.mjs' <<<"$archive_listing"
    package_json="$(tar -xOzf "$artifact" package/package.json)"
    [[ "$(jq -r '.version' <<<"$package_json")" == "$pkg_version" ]]
    [[ "$(jq -r '.bin["issue-orchestrator"]' <<<"$package_json")" == bin/supervisor.mjs ]]
    ! grep -Fq 'issue-orchestrator/archive/' "$devcontainer_dir/Dockerfile"
    grep -Fq "commit $full_commit (package version $pkg_version)." "$devcontainer_dir/Dockerfile"
    grep -Fq "SHA-256 $expected_sha." "$devcontainer_dir/Dockerfile"
    grep -Fq "COPY vendor/issue-orchestrator-$short_commit.tgz" "$devcontainer_dir/Dockerfile"
    grep -Fq "/opt/agent-devcontainer/vendor/issue-orchestrator-$short_commit.tgz" "$devcontainer_dir/Dockerfile"
    grep -Eq '^[[:space:]]+tmux \\' "$devcontainer_dir/Dockerfile"

    # Same derive-from-Dockerfile-then-verify treatment for the vendored
    # worktree-warden package (issue #63). Scoped to that package's own
    # comment block (anchored on its unique "Sadotu/worktree-warden" mention)
    # so the shared "# commit .../# SHA-256 ..." comment style doesn't pick up
    # issue-orchestrator's values instead.
    local ww_block ww_short_commit ww_full_commit ww_pkg_version ww_expected_sha
    local ww_artifact ww_artifact_sha ww_archive_listing ww_package_json
    ww_block="$(grep -A10 -F 'Sadotu/worktree-warden' "$devcontainer_dir/Dockerfile")"
    ww_short_commit="$(grep -oP '(?<=COPY vendor/worktree-warden-)[0-9a-f]+(?=\.tgz)' "$devcontainer_dir/Dockerfile" | head -1)"
    [[ -n $ww_short_commit ]]
    ww_full_commit="$(grep -oP '(?<=# commit )[0-9a-f]+' <<<"$ww_block" | head -1)"
    ww_pkg_version="$(grep -oP '(?<=package version )[0-9.]+(?=\)\.)' <<<"$ww_block" | head -1)"
    ww_expected_sha="$(grep -oP '(?<=SHA-256 )[0-9a-f]+' <<<"$ww_block" | head -1)"
    [[ $ww_full_commit == "$ww_short_commit"* ]]

    ww_artifact="$devcontainer_dir/vendor/worktree-warden-$ww_short_commit.tgz"

    [[ -f $ww_artifact ]]
    ww_artifact_sha="$(sha256sum "$ww_artifact")"
    [[ ${ww_artifact_sha%% *} == "$ww_expected_sha" ]]
    ww_archive_listing="$(tar -tzf "$ww_artifact")"
    grep -Fxq 'package/package.json' <<<"$ww_archive_listing"
    grep -Fxq 'package/bin/worktree-warden.js' <<<"$ww_archive_listing"
    ww_package_json="$(tar -xOzf "$ww_artifact" package/package.json)"
    [[ "$(jq -r '.version' <<<"$ww_package_json")" == "$ww_pkg_version" ]]
    [[ "$(jq -r '.bin["worktree-warden"]' <<<"$ww_package_json")" == bin/worktree-warden.js ]]
    ! grep -Fq 'worktree-warden/archive/' "$devcontainer_dir/Dockerfile"
    grep -Fq "commit $ww_full_commit (package version $ww_pkg_version)." "$devcontainer_dir/Dockerfile"
    grep -Fq "SHA-256 $ww_expected_sha." "$devcontainer_dir/Dockerfile"
    grep -Fq "COPY vendor/worktree-warden-$ww_short_commit.tgz" "$devcontainer_dir/Dockerfile"
    grep -Fq "/opt/agent-devcontainer/vendor/worktree-warden-$ww_short_commit.tgz" "$devcontainer_dir/Dockerfile"

    # worktree-warden vendor path must be part of the shared npm install -g
    # block (same cache-clean layer as claude-code/codex/issue-orchestrator).
    local ww_npm_install_block
    ww_npm_install_block="$(sed -n '/^RUN npm install -g \\$/,/npm cache clean --force$/p' "$devcontainer_dir/Dockerfile")"
    grep -Fq "/opt/agent-devcontainer/vendor/worktree-warden-$ww_short_commit.tgz" <<<"$ww_npm_install_block"

    # start-worktree-warden.sh / worktree-warden-summary.sh: baked onto the
    # image by another task running in parallel — only their Dockerfile
    # wiring is this task's concern, not their content.
    grep -Fq 'start-worktree-warden.sh' "$devcontainer_dir/Dockerfile"
    grep -Fq 'worktree-warden-summary.sh' "$devcontainer_dir/Dockerfile"
    grep -Fq '/opt/agent-devcontainer/start-worktree-warden.sh' "$devcontainer_dir/Dockerfile"
    grep -Fq '/opt/agent-devcontainer/worktree-warden-summary.sh' "$devcontainer_dir/Dockerfile"

    # Image version identifier (issue #24). The build bakes a VERSION file and
    # a PATH command from build-args the publish workflow supplies; setup
    # reports it.
    local repo_root workflow
    repo_root="$(dirname "$devcontainer_dir")"
    workflow="$repo_root/.github/workflows/publish-image.yml"
    grep -Eq '^ARG IMAGE_VERSION' "$devcontainer_dir/Dockerfile"
    grep -Eq '^ARG IMAGE_BUILD_DATE' "$devcontainer_dir/Dockerfile"
    grep -Fq '/opt/agent-devcontainer/VERSION' "$devcontainer_dir/Dockerfile"
    grep -Fq 'COPY version.sh /usr/local/bin/agent-devcontainer-version' "$devcontainer_dir/Dockerfile"
    [[ -f "$devcontainer_dir/version.sh" ]]
    grep -Fq '/opt/agent-devcontainer/VERSION' "$devcontainer_dir/version.sh"
    grep -Fq 'IMAGE_VERSION=${{ github.sha }}' "$workflow"
    grep -Fq 'agent-devcontainer image version' "$devcontainer_dir/setup-agents.sh"
    grep -Fq 'TOOLDIR/VERSION' "$devcontainer_dir/setup-agents.sh"
    # `landed` post-merge helper: baked onto PATH the same way.
    grep -Fq 'COPY landed.sh /usr/local/bin/landed' "$devcontainer_dir/Dockerfile"
    [[ -f "$devcontainer_dir/landed.sh" ]]

    # `ghx` App-token wrapper and `why-failed` CI summariser (issue #45) are
    # baked onto PATH; `ghx` remains documented, and its token must only ever
    # reach `gh` through the environment, never a traced command line.
    grep -Fq 'COPY ghx.sh /usr/local/bin/ghx' "$devcontainer_dir/Dockerfile"
    grep -Fq 'COPY why-failed.sh /usr/local/bin/why-failed' "$devcontainer_dir/Dockerfile"
    [[ -f "$devcontainer_dir/ghx.sh" ]]
    [[ -f "$devcontainer_dir/why-failed.sh" ]]
    grep -Fq 'COPY gh.sh /usr/local/bin/gh' "$devcontainer_dir/Dockerfile"
    grep -Fq 'chmod 0755 /usr/local/bin/gh' "$devcontainer_dir/Dockerfile"
    [[ -f "$devcontainer_dir/gh.sh" ]]
    grep -Fq 'exec /usr/bin/gh "$@"' "$devcontainer_dir/ghx.sh"
    grep -Fq 'GH_TOKEN="$(GITHUB_APP_REPO=$repo /opt/agent-devcontainer/gh-app-token.sh)" /usr/bin/gh "$@"' "$devcontainer_dir/landed.sh"
    grep -Fq 'GH_TOKEN="$(GITHUB_APP_REPO=$repo /opt/agent-devcontainer/gh-app-token.sh)" /usr/bin/gh "$@"' "$devcontainer_dir/why-failed.sh"
    grep -Fq 'GH_TOKEN="$("$TOOLDIR/gh-app-token.sh")" /usr/bin/gh pr list' "$devcontainer_dir/refresh-skills.sh"
    grep -Fq 'GH_TOKEN="$("$TOOLDIR/gh-app-token.sh")" /usr/bin/gh pr create' "$devcontainer_dir/refresh-skills.sh"
    grep -q 'GH_TOKEN=' "$devcontainer_dir/ghx.sh"
    # Never ENABLES xtrace (no `set -x`/`set -ex` in command position — comments
    # and the `set +x` defence below don't count), and DOES disable inherited
    # tracing before touching the token.
    ! grep -qE '^[[:space:]]*set[[:space:]]+-[a-z]*x' "$devcontainer_dir/ghx.sh"
    grep -qE '^[[:space:]]*(\{[[:space:]]*)?set[[:space:]]+\+x' "$devcontainer_dir/ghx.sh"
    grep -Fq 'ghx' "$repo_root/README.md"
    [[ "$(wc -l <"$repo_root/README.md")" -lt 60 ]]

    temp_dir="$(mktemp -d)"
    printf -v cleanup 'rm -rf -- %q' "$temp_dir"
    trap "$cleanup" EXIT

    cat >"$temp_dir/issue-orchestrator" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$PWD" >"$START_TEST_LOG"
printf 'argc=%s\n' "$#" >>"$START_TEST_LOG"
exit 37
EOF
    chmod +x "$temp_dir/issue-orchestrator"

    # Fake `curl` standing in for the Sentinel health probe: logs the args it
    # was called with and exits with $CURL_EXIT_CODE (default 0, i.e. Sentinel
    # healthy), so both the reachable and unreachable paths are exercised
    # without touching a real network.
    cat >"$temp_dir/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CURL_TEST_LOG"
exit "${CURL_EXIT_CODE:-0}"
EOF
    chmod +x "$temp_dir/curl"

    PATH="$temp_dir:$PATH"
    export START_TEST_LOG="$temp_dir/invocation"
    export CURL_TEST_LOG="$temp_dir/curl-invocations"
    # shellcheck source=../start-work.sh
    source "$(dirname "$0")/../start-work.sh"

    assert_invalid_usage
    assert_invalid_usage work extra
    assert_invalid_usage nope

    : >"$CURL_TEST_LOG"
    set +e
    start work
    status=$?
    set -e
    [[ $status -eq 37 ]]
    mapfile -t invocation <"$START_TEST_LOG"
    [[ ${invocation[0]} == "$PWD" ]]
    [[ ${invocation[1]} == argc=0 ]]
    [[ ${#invocation[@]} -eq 2 ]]
    mapfile -t curl_calls <"$CURL_TEST_LOG"
    [[ ${#curl_calls[@]} -eq 1 ]]
    [[ ${curl_calls[0]} == *'http://usage-sentinel:4317/health'* ]]

    # Sentinel unreachable: issue-orchestrator must never run, and the error
    # must name Sentinel so it's not mistaken for an unrelated failure.
    rm -f "$START_TEST_LOG"
    : >"$CURL_TEST_LOG"
    set +e
    output="$(CURL_EXIT_CODE=7 start work 2>&1)"
    status=$?
    set -e
    [[ $status -ne 0 ]]
    [[ ! -f $START_TEST_LOG ]]
    [[ $output == *'Sentinel unreachable'* ]]
    [[ $output == *'http://usage-sentinel:4317'* ]]

    # SENTINEL_URL override must reach the probe, not just the default.
    : >"$CURL_TEST_LOG"
    set +e
    SENTINEL_URL='http://custom-sentinel:9999' start work
    status=$?
    set -e
    [[ $status -eq 37 ]]
    mapfile -t custom_curl_calls <"$CURL_TEST_LOG"
    [[ ${#custom_curl_calls[@]} -eq 1 ]]
    [[ ${custom_curl_calls[0]} == *'http://custom-sentinel:9999/health'* ]]

    # worktree-warden summary sourcing is guarded by `[[ -r
    # /opt/agent-devcontainer/worktree-warden-summary.sh ]]`, an absolute
    # baked-image path that doesn't exist in this source-only checkout — so
    # the guard is false here and the above exact-invocation assertions
    # (argv/PWD/exit-code passthrough) are the regression proof that adding
    # the sourcing line didn't change `start work`'s behavior when the file
    # is absent. Actual summary-line content is covered by
    # worktree-warden-summary.test.sh; the guard's wiring itself is asserted
    # statically here (real baked-image behavior needs image_test).
    grep -Fq '/opt/agent-devcontainer/worktree-warden-summary.sh' "$devcontainer_dir/start-work.sh"
    grep -Fq 'worktree_warden_summary' "$devcontainer_dir/start-work.sh"

    # setup-agents.sh: worktree-warden update block mirrors issue-orchestrator's
    # (issue #63) — never probes with a bare/`--version` invocation (every
    # non-`status` argument starts the daemon or is rejected, neither is a
    # version probe), reads the version from `npm list -g` instead.
    grep -Fq 'npm install -g @nickysagan/worktree-warden@latest' "$devcontainer_dir/setup-agents.sh"
    grep -Fq 'npm list -g @nickysagan/worktree-warden' "$devcontainer_dir/setup-agents.sh"
    ! grep -Eq '\bworktree-warden[[:space:]]+--version\b' "$devcontainer_dir/setup-agents.sh"
}

image_test() {
    local image=$1 output status container_id="" refresh_dir

    refresh_dir="$(mktemp -d)"
    trap '[[ -z $container_id ]] || docker rm -f "$container_id" >/dev/null 2>&1 || true; rm -rf "$refresh_dir"' RETURN

    docker run --rm "$image" bash -c '
        command -v tmux >/dev/null &&
        test "$(command -v gh)" = /usr/local/bin/gh &&
        test -x /usr/local/bin/gh &&
        command -v claude >/dev/null &&
        command -v issue-orchestrator >/dev/null &&
        command -v worktree-warden >/dev/null &&
        test -x /opt/agent-devcontainer/gh-app-token.sh
    '
    docker run --rm "$image" bash -c 'node --check "$(command -v issue-orchestrator)"'
    docker run --rm "$image" bash -c 'node --check "$(command -v worktree-warden)"'

    # worktree-warden (issue #63): inert presence checks only — a plain
    # `docker run` never executes `postStartCommand` (devcontainer-CLI-only
    # lifecycle hook), so it can neither start nor be proven not-started here.
    # Real autostart dedup/gating is covered by start-worktree-warden.test.sh.
    docker run --rm "$image" bash -c '
        test -x /opt/agent-devcontainer/start-worktree-warden.sh &&
        test -x /opt/agent-devcontainer/worktree-warden-summary.sh
    '
    # `worktree-warden status` must run cleanly with no state dir present
    # (fresh container, no prior candidates) — no GitHub App token, no
    # network, no daemon start.
    [[ "$(docker run --rm "$image" bash -c 'worktree-warden status')" == *'worktree-warden status'* ]]

    # Version identifier is baked and inspectable from inside the container (issue #24).
    docker run --rm "$image" bash -c 'test -r /opt/agent-devcontainer/VERSION'
    [[ "$(docker run --rm "$image" bash -c 'agent-devcontainer-version')" == *version:* ]]
    # `landed` is on PATH and refuses to run without a PR number (exit 2).
    docker run --rm "$image" bash -c 'command -v landed >/dev/null'
    [[ "$(docker run --rm "$image" bash -c 'landed; echo $?' 2>/dev/null | tail -1)" == 2 ]]

    # `ghx` and `why-failed` (issue #45) are on PATH; `why-failed` rejects a
    # non-numeric argument with exit 2 without needing any auth or network.
    docker run --rm "$image" bash -c 'command -v ghx >/dev/null'
    docker run --rm "$image" bash -c 'command -v why-failed >/dev/null'
    [[ "$(docker run --rm "$image" bash -c 'why-failed nope; echo $?' 2>/dev/null | tail -1)" == 2 ]]
    docker run --rm "$image" bash -ic 'declare -F start >/dev/null'

    set +e
    output="$(docker run --rm "$image" bash -ic 'start' 2>&1)"
    status=$?
    set -e
    [[ $status -ne 0 ]]
    [[ $output == *'Usage: start work'* ]]

    mkdir -p "$refresh_dir/.devcontainer"
    printf 'stale\n' >"$refresh_dir/.devcontainer/dc"
    printf 'stale\n' >"$refresh_dir/.devcontainer/devcontainer.json"
    printf 'smoke-project\nSadotu\n4217970\ny\ny\n' | docker run --rm -i \
        -v "$refresh_dir:/out" "$image" init >/dev/null
    test -x "$refresh_dir/.devcontainer/dc"
    grep -Fq 'sentinel-update)' "$refresh_dir/.devcontainer/dc"
    node - "$refresh_dir/.devcontainer/devcontainer.json" <<'EOF'
const config = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
if (!config.runArgs.includes("--network=agent-services")) process.exit(1);
if (config.containerEnv.SENTINEL_URL !== "http://usage-sentinel:4317") process.exit(1);
if (config.postStartCommand !== "/opt/agent-devcontainer/start-worktree-warden.sh") process.exit(1);
EOF

    container_id="$(docker run -d "$image" sleep 30)"
    sleep 1
    [[ "$(docker inspect -f '{{.State.Running}}' "$container_id")" == true ]]
    [[ -z "$(docker exec "$container_id" pgrep -f '[i]ssue-orchestrator' || true)" ]]
    # postStartCommand is a devcontainer-CLI-only lifecycle hook, never
    # executed by a plain `docker run` (see the comment above the earlier
    # worktree-warden presence checks) — so warden must NOT be running here
    # either, same as issue-orchestrator above; this is a true negative this
    # test CAN prove (nothing invoked postStartCommand at all in this path).
    [[ -z "$(docker exec "$container_id" pgrep -f '[w]orktree-warden' || true)" ]]
}

[[ $# -eq 1 ]] || usage
if [[ $1 == --source-only ]]; then
    source_test
else
    image_test "$1"
fi
