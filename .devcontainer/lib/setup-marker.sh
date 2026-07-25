#!/usr/bin/env bash
# Readiness-marker plumbing for the agent devcontainer, sourced by
# setup-agents.sh (postCreate). Sourceable library — defines functions only,
# no top-level side effects, no `set -e` of its own (the sourcing script owns
# shell options), same contract as lib/bw-session.sh.
#
# The marker is the readiness contract consumed by issue-orchestrator (issue
# #31 / reader PR #46): a worker is only admitted once the marker exists, so
# workers never launch mid-`setup-agents.sh` while global agent CLIs are being
# reinstalled. setup-agents.sh removes any stale marker up front and re-creates
# it as its final successful action; `set -e` makes that final call unreachable
# on any failure, so a failed setup leaves the marker absent.
#
# Default path is under /run so a container rebuild clears it automatically
# (a stop/start of the same container retains it — setup already completed).
# AGENT_SETUP_MARKER overrides it, which is how the tests avoid the real /run.

setup_marker_path() {
  printf '%s' "${AGENT_SETUP_MARKER:-/run/agent-setup-complete}"
}

# Remove any stale marker. Idempotent: no error when it does not exist.
setup_marker_reset() {
  rm -f "$(setup_marker_path)"
}

# Create the marker atomically: an observer must never see a partially written
# file. Write a temp file in the marker's OWN directory (same filesystem, so
# the rename is atomic), make it world-readable (issue-orchestrator runs as a
# possibly-different user), then rename it into place.
setup_marker_complete() {
  local target dir tmp
  target="$(setup_marker_path)"
  dir="$(dirname "$target")"
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.agent-setup-complete.XXXXXX")"
  printf 'agent-setup-complete\n' > "$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$target"
}
