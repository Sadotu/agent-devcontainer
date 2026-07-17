#!/usr/bin/env bash
# Git credential helper backed by a GitHub App installation token.
#
# Wire it up (already done by setup-agents.sh):
#   git config --global credential.https://github.com.helper \
#     '!/opt/agent-devcontainer/git-credential-github-app.sh'
#
# Git invokes this with "get" before each authenticated fetch/push; we answer
# with a freshly-minted (and cached) App installation token as the password.
set -euo pipefail

[ "${1:-}" = "get" ] || exit 0   # ignore store/erase

token="$("$(dirname "$0")/gh-app-token.sh")"
printf 'username=x-access-token\n'
printf 'password=%s\n' "$token"
