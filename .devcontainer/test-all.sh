#!/usr/bin/env bash
#
# Run every .devcontainer/test/*.sh suite with the correct invocation and
# report one line per suite. Exits nonzero if any suite fails.
#
# Usage:
#   test-all.sh                 # source mode: image-smoke.sh --source-only (no Docker)
#   test-all.sh IMAGE_TAG       # image mode: passes IMAGE_TAG to image-smoke.sh too
#
# image-smoke.sh is the odd suite out — invoked bare it exits 2 with a usage
# message. This runner always gives it either --source-only or the image tag,
# so a clean tree never reads as a failure. Every other suite runs bare.
#
# Discovery is a plain *.sh glob, so adding a new suite needs no edit here.
# TEST_ALL_DIR overrides the discovered directory (used by the runner's test).
set -uo pipefail

FAIL_TAIL=30

test_dir="${TEST_ALL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/test" && pwd)}"
image_tag="${1:-}"

failed=0
ran=0
for suite in "$test_dir"/*.sh; do
    [ -e "$suite" ] || continue
    name="$(basename "$suite")"
    if [ "$name" = image-smoke.sh ]; then
        output="$(bash "$suite" "${image_tag:---source-only}" 2>&1)"
    else
        output="$(bash "$suite" 2>&1)"
    fi
    status=$?
    ran=$((ran + 1))
    if [ "$status" -eq 0 ]; then
        printf 'PASS  %s\n' "$name"
    else
        printf 'FAIL  %s (exit %d)\n' "$name" "$status"
        printf '%s\n' "$output" | tail -n "$FAIL_TAIL" | sed 's/^/      | /'
        failed=$((failed + 1))
    fi
done

printf -- '---\n'
if [ "$ran" -eq 0 ]; then
    printf 'no suites found in %s\n' "$test_dir" >&2
    exit 1
fi
if [ "$failed" -ne 0 ]; then
    printf '%d/%d suites failed\n' "$failed" "$ran" >&2
    exit 1
fi
printf 'all %d suites passed\n' "$ran"
