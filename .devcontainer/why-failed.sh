#!/usr/bin/env bash
# `why-failed [run-id]` — why did a CI run fail, in a handful of lines?
#
# `gh run view --log-failed` prints hundreds of timestamped lines; the useful
# content is a few — which step failed, the failing assertion, the exit code.
# This prints only those, then names the full command to escalate to.
#
# With no argument it summarises the most recent failed run in the current
# repository (or $GITHUB_APP_REPO). Give a run id to target a specific run.
#
# Plain bash + gh — no coupling to Claude, Codex, or any other agent. Inside the
# devcontainer it authenticates as the GitHub App; anywhere else it falls back
# to whatever `gh` is already authenticated as.
set -euo pipefail

MATCH_MAX=20   # decisive lines to show when the failure classifies
TAIL_MAX=20    # log lines to show when it does not

usage() { echo "usage: why-failed [run-id]" >&2; exit 2; }

[ "$#" -le 1 ] || usage
run_id="${1:-}"
if [ -n "$run_id" ]; then
  case "$run_id" in *[!0-9]*) echo "why-failed: run id must be numeric: '$run_id'" >&2; exit 2 ;; esac
fi

repo="${GITHUB_APP_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null \
  || git remote get-url origin | sed -E 's#.*[:/]([^/]+/[^/.]+)(\.git)?$#\1#')}"

# The GitHub App helper exists only inside the agent devcontainer; anywhere
# else, fall back to whatever `gh` is already authenticated as.
if [ -x /opt/agent-devcontainer/gh-app-token.sh ]; then
  GH() { GH_TOKEN="$(GITHUB_APP_REPO=$repo /opt/agent-devcontainer/gh-app-token.sh)" /usr/bin/gh "$@"; }
else
  GH() { gh "$@"; }
fi

# Default to the newest failed run when none is named.
if [ -z "$run_id" ]; then
  run_id="$(GH run list --repo "$repo" --status failure --limit 1 \
    --json databaseId -q '.[0].databaseId // empty')"
  if [ -z "$run_id" ]; then
    echo "why-failed: no failed runs found for $repo" >&2
    exit 0
  fi
fi

run_json="$(GH run view "$run_id" --repo "$repo" \
  --json displayTitle,workflowName,url,conclusion,jobs)"

printf '%s' "$run_json" | jq -r \
  '"== run \($run_id): \(.workflowName) — \(.displayTitle)",
   "   result: \(.conclusion // "?")",
   "   url:    \(.url)"' --arg run_id "$run_id"

# Which step actually failed — the first thing worth knowing.
printf '%s' "$run_json" | jq -r '
  .jobs[]? | select(.conclusion=="failure") as $j
  | ($j.steps[]? | select(.conclusion=="failure") | "   step:   \($j.name) › \(.name)")'

# Decisive lines from the failed step logs. --log-failed is verbose and
# timestamp-prefixed; keep only the lines that mark a failure and trim the
# leading job/step/timestamp columns so the message is readable.
log="$(GH run view "$run_id" --repo "$repo" --log-failed 2>/dev/null || true)"
strip='s/^[^\t]*\t[^\t]*\t[0-9T:.Z-]+ ?//'
markers='##\[error\]|[Ee]rror:|[Ee]xception|AssertionError|assert|[Ee]xit code|Process completed with exit code|npm ERR!|panic:|Traceback|( |^)FAIL(ED|URE)?( |:|$)|not ok'

if [ -n "$log" ]; then
  matched="$(printf '%s\n' "$log" | grep -aE "$markers" | tail -n "$MATCH_MAX" | sed -E "$strip" || true)"
  if [ -n "$matched" ]; then
    printf '%s\n' "$matched" | sed 's/^/   | /'
  else
    echo "   (could not classify; last $TAIL_MAX log lines:)"
    printf '%s\n' "$log" | tail -n "$TAIL_MAX" | sed -E "$strip" | sed 's/^/   | /'
  fi
else
  echo "   (no failed-step logs — likely a setup, cancellation, or infra failure)"
fi

echo "   escalate: gh run view $run_id --repo $repo --log-failed"
