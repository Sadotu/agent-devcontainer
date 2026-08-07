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

    # Image version identifier (issue #24). The build bakes a VERSION file and
    # a PATH command from build-args the publish workflow supplies; setup and
    # the README surface it.
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

    # `ghx` App-token wrapper and `why-failed` CI summariser (issue #45): baked
    # onto PATH beside `landed`, documented, and — for `ghx` — the token must
    # only ever reach `gh` through the environment, never a traced command line.
    grep -Fq 'COPY ghx.sh /usr/local/bin/ghx' "$devcontainer_dir/Dockerfile"
    grep -Fq 'COPY why-failed.sh /usr/local/bin/why-failed' "$devcontainer_dir/Dockerfile"
    [[ -f "$devcontainer_dir/ghx.sh" ]]
    [[ -f "$devcontainer_dir/why-failed.sh" ]]
    grep -Fq 'exec gh' "$devcontainer_dir/ghx.sh"
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

    PATH="$temp_dir:$PATH"
    export START_TEST_LOG="$temp_dir/invocation"
    # shellcheck source=../start-work.sh
    source "$(dirname "$0")/../start-work.sh"

    assert_invalid_usage
    assert_invalid_usage work extra
    assert_invalid_usage nope

    set +e
    start work
    status=$?
    set -e
    [[ $status -eq 37 ]]
    mapfile -t invocation <"$START_TEST_LOG"
    [[ ${invocation[0]} == "$PWD" ]]
    [[ ${invocation[1]} == argc=0 ]]
    [[ ${#invocation[@]} -eq 2 ]]
}

image_test() {
    local image=$1 output status container_id="" refresh_dir

    refresh_dir="$(mktemp -d)"
    trap '[[ -z $container_id ]] || docker rm -f "$container_id" >/dev/null 2>&1 || true; rm -rf "$refresh_dir"' RETURN

    docker run --rm "$image" bash -c '
        command -v tmux >/dev/null &&
        command -v gh >/dev/null &&
        command -v claude >/dev/null &&
        command -v issue-orchestrator >/dev/null &&
        test -x /opt/agent-devcontainer/gh-app-token.sh
    '
    docker run --rm "$image" bash -c 'node --check "$(command -v issue-orchestrator)"'

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
EOF

    container_id="$(docker run -d "$image" sleep 30)"
    sleep 1
    [[ "$(docker inspect -f '{{.State.Running}}' "$container_id")" == true ]]
    [[ -z "$(docker exec "$container_id" pgrep -f '[i]ssue-orchestrator' || true)" ]]
}

[[ $# -eq 1 ]] || usage
if [[ $1 == --source-only ]]; then
    source_test
else
    image_test "$1"
fi
