---
name: github-issue
description: Use when working a GitHub issue in this repo — runs the whole flow end to end: select the issue, derive the design and plan straight from the issue description, implement in an isolated worktree via subagents, verify against the issue, and open a PR that carries the generated spec + plan and closes the issue.
---

# GitHub Issue — End to End

A single continuous workflow. Run all phases in order in one session; there is no plan/build handoff.

**The issue description is the leading input.** It seeds the design work and is the specification you verify the result against. A design and an implementation plan are still produced and committed so they travel with the PR — but they are a record for the PR, not something the user needs to circle back and read. The user's input happens live in the design phase (below); once that design is approved, the written spec and plan are just artifacts.

This skill is repo-agnostic: it always operates on the repo it's invoked from. Resolve that repo dynamically — never hardcode an owner/repo:

```bash
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null \
  || git remote get-url origin | sed -E 's#.*[:/]([^/]+/[^/.]+)(\.git)?$#\1#')"
WORKSPACE="$(git rev-parse --show-toplevel)"
```

**Auth:** use the GitHub App token for every `gh` command — set `GITHUB_APP_REPO` to the resolved repo. `git` pushes are already authenticated by the global credential helper (`.devcontainer/git-credential-github-app.sh`); no manual token needed for push.

```bash
GH_TOKEN="$(GITHUB_APP_REPO=$REPO $WORKSPACE/.devcontainer/gh-app-token.sh)" gh <cmd> --repo "$REPO"
```

---

## Phase 1 — Select and Understand

Resolve the issue number:

- Full GitHub issue URL: extract the number (and confirm the URL's repo matches `$REPO`; if it doesn't, stop and ask — this skill only works issues in the current repo).
- Bare number: use it directly.
- No issue named: list open issues and ask the user to choose.

```bash
GH_TOKEN="$(GITHUB_APP_REPO=$REPO $WORKSPACE/.devcontainer/gh-app-token.sh)" gh issue list --repo "$REPO"
```

Read the selected issue and treat its description as the specification:

```bash
GH_TOKEN="$(GITHUB_APP_REPO=$REPO $WORKSPACE/.devcontainer/gh-app-token.sh)" gh issue view <number> --repo "$REPO"
```

Summarize: request, current behavior, expected outcome, acceptance criteria, linked context. Inspect the relevant files before trusting the issue's diagnosis. Keep the issue number and original acceptance criteria visible throughout.

---

## Phase 2 — Synchronize and Isolate (before any issue commit)

**REQUIRED SUB-SKILL:** Use `superpowers:using-git-worktrees`.

**CRITICAL — synchronize before writing or committing issue artifacts.** `git fetch` updates `origin/main`, not local `main`. Creating design/plan commits in the primary worktree before isolation pollutes local `main` and makes it diverge.

Start from a clean primary worktree with `main` checked out, fetch, and fast-forward only when safe:

```bash
test "$(git branch --show-current)" = main
test -z "$(git status --porcelain)"
git fetch origin
git merge-base --is-ancestor main origin/main
git merge --ff-only origin/main
test "$(git rev-parse main)" = "$(git rev-parse origin/main)"
git worktree add -b agent/<number>-<slug> <worktree-path> origin/main
```

If branch, cleanliness, or ancestry guard fails, stop. Preserve user work; do not reset, merge divergent histories, or commit issue artifacts in the primary worktree. Report the exact condition and request direction.

Use a short kebab-case slug of three to five words. From this point onward, run all file writes, commits, tests, and Git commands in `<worktree-path>` unless a command explicitly inspects the primary worktree. Never commit issue work directly to `main`.

---

## Phase 3 — Design and Plan (inside issue worktree)

**REQUIRED SUB-SKILL:** Use `superpowers:brainstorming`, seeded with the issue description and your codebase findings. Follow its approval gates — this is where the user's input on the design happens. After the design is approved, use `superpowers:writing-plans` to produce the plan.

Produce and **commit** two artifacts inside `<worktree-path>` so they land in the PR diff:

- Design: `docs/superpowers/specs/<YYYY-MM-DD>-<slug>-design.md`
- Plan: `docs/superpowers/plans/<YYYY-MM-DD>-<slug>.md`

The plan must record:

- Issue number and URL
- Original acceptance criteria
- PR closing reference: `Closes #<number>`

These files are for the record and for the PR — the user is not expected to review them before implementation continues.

---

## Phase 4 — Implement

**REQUIRED SUB-SKILL:** Use `superpowers:subagent-driven-development`.

Execute the plan task by task with fresh subagents and the skill's review stages when subagent tools are available (discover deferred tools with `tool_search` if needed). If subagent tools are unavailable, say so and execute directly while preserving the same task boundaries, test-first discipline, and review checkpoints — do not silently omit review.

Follow `superpowers:test-driven-development` for every behavior change unless the user explicitly approves an exception.

---

## Phase 5 — Verify Against the Issue

**REQUIRED SUB-SKILL:** Use `superpowers:verification-before-completion`.

Run focused tests plus the repository checks appropriate to the changed surface. Re-read the original issue and verify each acceptance criterion against current evidence:

```bash
GH_TOKEN="$(GITHUB_APP_REPO=$REPO $WORKSPACE/.devcontainer/gh-app-token.sh)" gh issue view <number> --repo "$REPO"
```

Do not claim completion from prior output, expected behavior, or a passing subset that does not cover the requested outcome.

---

## Phase 6 — Finish (with stale-base guard)

**REQUIRED SUB-SKILL:** Use `superpowers:finishing-a-development-branch`.

**Before pushing, guard against a stale base** — a branch that has fallen behind `origin/main` produces a bloated, dangerous PR diff:

```bash
git fetch origin
base=$(git merge-base origin/main HEAD)
behind=$(git rev-list --count "$base"..origin/main)
[ "$behind" -gt 50 ] && echo "STALE BASE: $behind commits behind origin/main — rebase before PR"
```

If stale, `git rebase origin/main` (resolve conflicts, drop already-merged commits), then re-run Phase 5. Confirm `git diff --stat origin/main...HEAD` shows only your intended files before opening the PR.

When creating the PR:

- Title clearly references the issue.
- Body summarizes the behavior change and the verification performed, **and links the committed spec + plan paths** (`docs/superpowers/specs/…`, `docs/superpowers/plans/…`) so reviewers can find them.
- Include exactly one closing reference: `Closes #<number>`.
- Push the issue branch and create the PR only after verification passes. Report the branch name and PR URL.

Do not merge unless the user explicitly requests it.

---

## Phase 7 — Post-Merge Cleanup

Run this phase when the user reports the PR merged or authenticated GitHub state reports `MERGED`. Never treat a merely closed PR as merged.

Resolve the merged branch from the PR, then enforce the `agent/*` boundary:

```bash
PR_JSON="$(GH_TOKEN="$(GITHUB_APP_REPO=$REPO $WORKSPACE/.devcontainer/gh-app-token.sh)" \
  gh pr view <pr-number> --repo "$REPO" --json state,headRefName)"
test "$(printf '%s' "$PR_JSON" | jq -r .state)" = MERGED
BRANCH="$(printf '%s' "$PR_JSON" | jq -r .headRefName)"
case "$BRANCH" in agent/*) ;; *) echo "Refusing to delete non-agent branch: $BRANCH"; exit 1 ;; esac
```

Fetch and prove the branch tip landed in `origin/main`. Find its registered worktree and require it to be clean, including untracked files:

```bash
git -C "$WORKSPACE" fetch origin
git -C "$WORKSPACE" merge-base --is-ancestor "$BRANCH" origin/main
ISSUE_WORKTREE="$(git -C "$WORKSPACE" worktree list --porcelain | awk -v ref="refs/heads/$BRANCH" '
  /^worktree / { wt=substr($0, 10) }
  $0 == "branch " ref { print wt }
')"
test -n "$ISSUE_WORKTREE"
test -z "$(git -C "$ISSUE_WORKTREE" status --porcelain)"
```

Stop and report the failed guard without cleanup if any command above fails. Once all guards pass, remove the worktree from the primary repo, prune its metadata, delete the local branch safely, and delete the matching remote branch when it still exists:

```bash
cd "$WORKSPACE"
git worktree remove "$ISSUE_WORKTREE"
git worktree prune
git branch -d "$BRANCH"
if git ls-remote --exit-code --heads origin "refs/heads/$BRANCH" >/dev/null 2>&1; then
  git push origin --delete "$BRANCH"
fi
```

Fast-forward local `main` without resetting or cleaning user files:

```bash
test "$(git branch --show-current)" = main
git merge-base --is-ancestor main origin/main
git merge --ff-only origin/main
test "$(git rev-parse main)" = "$(git rev-parse origin/main)"
```

Finally, confirm the issue closed; close it manually if GitHub did not process the PR closing reference:

```bash
ISSUE_STATE="$(GH_TOKEN="$(GITHUB_APP_REPO=$REPO $WORKSPACE/.devcontainer/gh-app-token.sh)" \
  gh issue view <number> --repo "$REPO" --json state -q .state)"
if [ "$ISSUE_STATE" != CLOSED ]; then
  GH_TOKEN="$(GITHUB_APP_REPO=$REPO $WORKSPACE/.devcontainer/gh-app-token.sh)" \
    gh issue close <number> --repo "$REPO"
fi
```

Never use forced worktree removal, `git branch -D`, reset, clean, or force-push during post-merge cleanup. Never delete `main`, `master`, `develop`, `release/*`, or `hotfix/*` locally or remotely.

---

## Non-Negotiable Rules

- The issue description is the leading input and the spec you verify against; the design is settled interactively via `superpowers:brainstorming`, then recorded.
- Still generate **and commit** the spec + plan so they ride in the PR (the user need not re-read them).
- Before any issue artifact is written, safely fast-forward clean local `main`, then branch from freshly fetched `origin/main`; never branch from local `main` or another feature branch.
- If local `main` diverged or the primary worktree is dirty/not on `main`, stop without mutating it.
- After isolation, write and commit every issue artifact inside the issue worktree only.
- Run the stale-base guard before every PR; rebase if behind.
- Do not implement in the user's dirty primary worktree; do not commit directly to `main`.
- Do not bypass failing tests or omit verification details.
- Ensure the PR body has exactly one correct closing reference.
- After confirmed merge, complete Phase 7: remove the clean issue worktree, delete local and remote `agent/*` branches, fast-forward local `main`, and confirm the tracker issue closed.
