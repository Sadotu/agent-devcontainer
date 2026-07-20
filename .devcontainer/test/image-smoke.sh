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
    test_dir="$(cd "$(dirname "$0")" && pwd)"
    devcontainer_dir="$(dirname "$test_dir")"
    artifact="$devcontainer_dir/vendor/issue-orchestrator-bb48f1c5f54e.tgz"

    [[ -f $artifact ]]
    artifact_sha="$(sha256sum "$artifact")"
    [[ ${artifact_sha%% *} == 6d84b28fddf7f0696105fb7516a7239d643d3179c67161a79e2b6fd3d638259e ]]
    archive_listing="$(tar -tzf "$artifact")"
    grep -Fxq 'package/package.json' <<<"$archive_listing"
    grep -Fxq 'package/bin/supervisor.mjs' <<<"$archive_listing"
    package_json="$(tar -xOzf "$artifact" package/package.json)"
    [[ "$(jq -r '.version' <<<"$package_json")" == 0.1.0 ]]
    [[ "$(jq -r '.bin["issue-orchestrator"]' <<<"$package_json")" == bin/supervisor.mjs ]]
    ! grep -Fq 'issue-orchestrator/archive/' "$devcontainer_dir/Dockerfile"
    grep -Fq 'commit bb48f1c5f54eda3881cec68020524ff83139ee7c' "$devcontainer_dir/Dockerfile"
    grep -Fq 'SHA-256 6d84b28fddf7f0696105fb7516a7239d643d3179c67161a79e2b6fd3d638259e' "$devcontainer_dir/Dockerfile"
    grep -Fq 'COPY vendor/issue-orchestrator-bb48f1c5f54e.tgz' "$devcontainer_dir/Dockerfile"
    grep -Fq '/opt/agent-devcontainer/vendor/issue-orchestrator-bb48f1c5f54e.tgz' "$devcontainer_dir/Dockerfile"

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
    local image=$1 output status container_id

    docker run --rm "$image" bash -c 'command -v issue-orchestrator >/dev/null'
    docker run --rm "$image" bash -c 'node --check "$(command -v issue-orchestrator)"'
    docker run --rm "$image" bash -ic 'declare -F start >/dev/null'

    set +e
    output="$(docker run --rm "$image" bash -ic 'start' 2>&1)"
    status=$?
    set -e
    [[ $status -ne 0 ]]
    [[ $output == *'Usage: start work'* ]]

    container_id="$(docker run -d "$image" sleep 30)"
    trap 'docker rm -f "$container_id" >/dev/null 2>&1 || true' RETURN
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
