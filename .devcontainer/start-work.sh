start() {
    if [[ $# -ne 1 || $1 != work ]]; then
        printf 'Usage: start work\n' >&2
        return 2
    fi

    if [[ -r /opt/agent-devcontainer/worktree-warden-summary.sh ]]; then
        # shellcheck source=worktree-warden-summary.sh
        source /opt/agent-devcontainer/worktree-warden-summary.sh
        worktree_warden_summary
    fi

    command issue-orchestrator
}
