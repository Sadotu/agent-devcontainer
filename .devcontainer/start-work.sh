start() {
    if [[ $# -ne 1 || $1 != work ]]; then
        printf 'Usage: start work\n' >&2
        return 2
    fi

    command issue-orchestrator "$@"
}
