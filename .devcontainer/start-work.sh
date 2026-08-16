start() {
    if [[ $# -ne 1 || $1 != work ]]; then
        printf 'Usage: start work\n' >&2
        return 2
    fi

    # issue-orchestrator relies on Sentinel to pause this container at usage
    # thresholds (it never self-limits — see managedContainer.mjs / supervisor.mjs
    # in the vendored package). If Sentinel is unreachable that enforcement is
    # silently absent, so refuse to start rather than let workers run unbounded.
    # `dc up` on the host ensures Sentinel is healthy before this container ever
    # starts, so this should only trip if it died or got disconnected afterward.
    local sentinel_url="${SENTINEL_URL:-http://usage-sentinel:4317}"
    if ! curl -fsS --max-time 3 -o /dev/null "$sentinel_url/health" 2>/dev/null; then
        printf 'Sentinel unreachable at %s — refusing to start issue-orchestrator (it cannot enforce usage-based pausing without Sentinel). Run `dc up` on the host to (re)start it.\n' "$sentinel_url" >&2
        return 1
    fi

    if [[ -r /opt/agent-devcontainer/worktree-warden-summary.sh ]]; then
        # shellcheck source=worktree-warden-summary.sh
        source /opt/agent-devcontainer/worktree-warden-summary.sh
        worktree_warden_summary
    fi

    command issue-orchestrator
}
