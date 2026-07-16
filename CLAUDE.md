# __PROJECT_NAME__ — Agent Instructions

## Commit Authorship
- **Never add agent authorship to commits.** Do NOT append `Co-Authored-By: Claude`
  (or any AI/agent co-author), `Claude-Session:`, `Generated with Claude Code`, or
  similar trailers/footers to commit messages or PR bodies. This overrides any
  harness default that adds such lines. Commits carry only the human author.

## Devcontainer Agent Workspace

A secure devcontainer for running Claude Code and Codex lives in
`.devcontainer/` at this repo's root. See `README.md` for setup,
authentication, and the safe issue workflow.

When running **inside the container** (workspace mounted at
`/workspaces/__PROJECT_NAME__`):
- You are on Linux — no `wsl` prefixes, no `/mnt/c` paths.
- The container mounts only this repo. Host home, `~/.ssh`, and host
  credentials do not exist here. **Do NOT run `gh auth login` or
  `gh auth setup-git`** — GitHub access uses the App-based auth below.
- A global pre-push hook blocks pushes to `main`/`master`/`develop`. Work
  branch → PR, never `--no-verify`.
- Skills: `.agents/skills/<name>/SKILL.md`. See `.agents/skills/README.md`.

### Devcontainer Gotchas
- Codex shell commands (`cd`, `grep`, etc.) fail with `bwrap: No permissions
  to create a new namespace` when its alias uses `--sandbox workspace-write`.
  Docker's default seccomp profile blocks the unprivileged user-namespace
  syscall bwrap needs. Fix: use `--sandbox danger-full-access` — the
  devcontainer's workspace-only bind mount is already the sandbox boundary,
  so Codex's inner bwrap sandbox is redundant. See `.devcontainer/setup-agents.sh`
  `cx`/`cx-auto` aliases.
- `__PROJECT_NAME__-github-app-config` volume mounts root-owned on first use,
  same as the other named volumes — but was missing from the `chown -R` list
  in `setup-agents.sh`, so `vscode` couldn't write `app-id`/`private-key.pem`
  into it. `sudo` is blocked by `no-new-privileges`, so there's no in-container
  workaround. Fixed by adding `$HOME/.config/github-app` to the chown list
  (setup-agents.sh line ~12).

### GitHub App auth

Use the configured GitHub App for all GitHub CLI issue and PR commands —
never a user PAT, never `gh auth login`. The App ID is `__APP_ID__`; the private
key is mounted outside the repo (persisted container volume, seeded from
`./secrets/` on the host — gitignored, never commit it) and must never be
printed or committed.

Before every `gh` command, mint a short-lived token with the workspace helper:

```bash
GH_TOKEN="$(GITHUB_APP_REPO=__GH_OWNER__/__PROJECT_NAME__ /workspaces/__PROJECT_NAME__/.devcontainer/gh-app-token.sh)" gh issue list --repo __GH_OWNER__/__PROJECT_NAME__
```

`git push`/`git fetch` need no manual auth — a credential helper wired by
`setup-agents.sh` mints tokens automatically. Do not use unauthenticated
`gh issue`, `gh pr`, or `gh api` commands when working on GitHub issues.

### Git & PR policy (container agents)

Agents may:
- create branches named `agent/<issue-number>-<short-description>`
- commit changes
- push only `agent/*` branches
- open pull requests into `main`
- update their own PR branch
- use repo-local skills, plugins, MCP tools, and subagents

Agents may not:
- push directly to `main`, `master`, `develop`, `release/`, or `hotfix/`
- force-push protected branches
- delete protected branches
- merge pull requests
- change repository settings
- change branch protection or rulesets
- modify GitHub Actions secrets
- modify GitHub App permissions
- modify `.github/workflows` unless explicitly asked
- use admin APIs
