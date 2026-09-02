#!/usr/bin/env bash
# Did a pull request actually land, end to end?
#
# Answers the three questions worth asking after a merge, in one call:
#   1. Is the PR merged, and at which commit?
#   2. Did its `Closes #n` references actually close those issues?
#   3. Did the workflow that merge triggered succeed?
#
# Question 3 is the one that bites: a merge is not a release. Anything baked
# into an image or published to a registry only reaches users once its
# post-merge workflow finishes, and that runs minutes after the merge reports
# success.
#
# Plain bash and `gh` — no coupling to Claude, Codex, or any other agent. A
# human typing it gets byte-identical output.
#
# Usage:
#   landed <pr-number>                  # repository of the current directory
#   landed <owner/repo> <pr-number>     # any repository
#   landed <pr-number> --wait           # block on a still-running workflow
set -euo pipefail

repo=""
pr=""
wait=0
for arg in "$@"; do
  case "$arg" in
    --wait) wait=1 ;;
    */*)    repo="$arg" ;;
    *[!0-9]*) echo "landed: unrecognised argument '$arg'" >&2; exit 2 ;;
    *)      pr="$arg" ;;
  esac
done

if [ -z "$pr" ]; then
  echo "usage: landed [owner/repo] <pr-number> [--wait]" >&2
  exit 2
fi

if [ -z "$repo" ]; then
  repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null \
    || git remote get-url origin | sed -E 's#.*[:/]([^/]+/[^/.]+)(\.git)?$#\1#')"
fi

# The GitHub App helper exists only inside the agent devcontainer; anywhere
# else, fall back to whatever `gh` is already authenticated as.
if [ -x /opt/agent-devcontainer/gh-app-token.sh ]; then
  GH() { GH_TOKEN="$(GITHUB_APP_REPO=$repo /opt/agent-devcontainer/gh-app-token.sh)" /usr/bin/gh "$@"; }
else
  GH() { gh "$@"; }
fi

echo "== $repo#$pr"

pr_json="$(GH pr view "$pr" --repo "$repo" --json state,mergedAt,mergeCommit,closingIssuesReferences)"

printf '%s' "$pr_json" | jq -r \
  '"   pr:    \(.state)\(if .mergedAt then " at \(.mergeCommit.oid[0:7]) on \(.mergedAt)" else "" end)"'

# closingIssuesReferences carries only number/url — no state or title — so each
# referenced issue needs its own lookup to answer "did it actually close?".
issues="$(printf '%s' "$pr_json" | jq -r '.closingIssuesReferences[]?.number')"
if [ -z "$issues" ]; then
  echo "   issue: none referenced"
else
  for n in $issues; do
    GH issue view "$n" --repo "$repo" --json number,state,title \
      -q '"   issue: #\(.number) \(.state) — \(.title)"'
  done
fi

# Question 3 only means anything for a merged PR: an unmerged one triggered
# nothing, and showing the newest run would invite reading someone else's merge
# as this PR's result.
case "$(printf '%s' "$pr_json" | jq -r .state)" in
  MERGED) ;;
  *) exit 0 ;;
esac

# The run that the merge itself triggered, i.e. the newest one on the default
# branch. Anything older is a previous merge and would be misleading here.
branch="$(GH repo view "$repo" --json defaultBranchRef -q .defaultBranchRef.name)"
run="$(GH run list --repo "$repo" --branch "$branch" --limit 1 \
  --json databaseId,name,status,conclusion \
  -q '.[0] // empty | "\(.databaseId)\t\(.name)\t\(.status)\t\(.conclusion // "-")"')"

if [ -z "$run" ]; then
  # Normal for a repo that releases on tags rather than on merge — this one
  # publishes from `v*` tags, so merging to the default branch triggers nothing.
  echo "   run:   none on $branch"
  exit 0
fi

IFS=$'\t' read -r run_id run_name run_status run_conclusion <<<"$run"

if [ "$wait" = 1 ] && [ "$run_status" != completed ]; then
  echo "   run:   $run_name $run_status — waiting..."
  GH run watch "$run_id" --repo "$repo" >/dev/null 2>&1 || true
  run_conclusion="$(GH run view "$run_id" --repo "$repo" --json conclusion -q .conclusion)"
  run_status=completed
fi

echo "   run:   $run_name $run_status/$run_conclusion"
[ "$run_status" = completed ] && [ "$run_conclusion" != success ] &&
  echo "   logs:  gh run view $run_id --repo $repo --log-failed"

exit 0
