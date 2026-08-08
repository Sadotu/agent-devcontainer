#!/usr/bin/env bash
# `ghx <gh args...>` — run `gh` authenticated as the GitHub App.
#
# Mints a short-lived App installation token for the current repository (or
# $GITHUB_APP_REPO) and execs `gh` with it injected. Replaces the ~100-char
#   GH_TOKEN="$(GITHUB_APP_REPO=owner/repo /opt/agent-devcontainer/gh-app-token.sh)" gh ...
# prefix retyped on every call.
#
# The token NEVER touches a command line and reaches `gh` only through the
# environment. This script never ENABLES tracing; before the token is minted it
# actively DISABLES any inherited trace (`set +x`), so even `bash -x ghx …` — a
# caller tracing into this script — cannot print the token. That leak (a live
# token printed by `set -x`) is exactly what forced a revoke once and what this
# wrapper exists to prevent.
#
# Outside the container the App helper is absent; `ghx` then just execs `gh`
# with whatever auth `gh` already has, so it is safe to use everywhere.
#
# Plain bash + gh — no coupling to Claude, Codex, or any other agent.
set -eu

HELPER=/opt/agent-devcontainer/gh-app-token.sh

if [ ! -x "$HELPER" ]; then
  # No App helper (running outside the devcontainer): fall back to ambient gh.
  exec gh "$@"
fi

# Resolve the repo the token is minted for. Explicit GITHUB_APP_REPO wins;
# otherwise derive owner/name from the current checkout, same as `landed`.
repo="${GITHUB_APP_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null \
  || git remote get-url origin | sed -E 's#.*[:/]([^/]+/[^/.]+)(\.git)?$#\1#')}"

# Disable any inherited xtrace so the token below is never printed, then
# command-substitute it into the GH_TOKEN environment of the exec'd gh. The
# value is never echoed and never appears as an argument.
{ set +x; } 2>/dev/null
GH_TOKEN="$(GITHUB_APP_REPO="$repo" "$HELPER")" exec gh "$@"
