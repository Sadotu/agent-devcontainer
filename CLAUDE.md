# agent-devcontainer — Agent Instructions

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
`/workspaces/agent-devcontainer`):
- You are on Linux — no `wsl` prefixes, no `/mnt/c` paths.
- The container mounts only this repo. Host home, `~/.ssh`, and host
  credentials do not exist here. **Do NOT run `gh auth login` or
  `gh auth setup-git`** — GitHub access uses the App-based auth below.
- A global pre-push hook blocks pushes to `main`/`master`/`develop`. Work
  branch → PR, never `--no-verify`.
- Skills: `.agents/skills/<name>/SKILL.md`. See `.agents/skills/README.md`.

### Devcontainer Gotchas
- Codex `--sandbox workspace-write` → `bwrap: No permissions to create a new
  namespace` (Docker seccomp blocks user-namespace syscall). Fix:
  `--sandbox danger-full-access` — bind mount is already the sandbox
  boundary. (`setup-agents.sh` `cx`/`cx-auto`.)
- `<project>-github-app-config` volume mounts root-owned on first use, was
  missing from `chown -R` list in `setup-agents.sh` → `vscode` couldn't write
  `app-id`/`private-key.pem` (no `sudo`, no in-container fix). Fixed: added
  `$HOME/.config/github-app` to chown list (setup-agents.sh line ~12).
- `dc` is host-side (runs `devcontainer up`, so can't be image-baked —
  must exist pre-pull). It's project-agnostic (derives PROJECT_NAME from
  repo dir), baked into image as template
  (`/opt/agent-devcontainer/templates/dc`) that `init` scaffolder emits
  per-project — single source of truth, no drift.
- `init` scaffolder (`/usr/local/bin/init`) is deliberately a plain PATH
  script, not `ENTRYPOINT` — keeps it out of `devcontainer up`'s container-
  start path (past source of stale-image/ownership/sudo pain). Also can't
  run as postCreate (too late — those are the files needed to start the
  container), hence separate `docker run IMAGE init`.
- `set -eo pipefail` + pipeline ending in `grep` with legitimate no-match
  (e.g. session-key parse on failed auth) → `grep` exit 1 trips `set -e`,
  script dies silently. Any expected-empty pipeline needs `|| true` on the
  whole pipeline, not just final assignment — see `BW_SESSION` extraction in
  `setup-agents.sh` (hit twice, same shape).
- `bw login` (no `--raw`) already unlocks vault + prints session key in its
  success banner — no separate `bw unlock` needed (avoids 2nd password
  prompt). `setup-agents.sh` parses key from banner text. Also strips ANSI,
  sets `NO_COLOR=1 FORCE_COLOR=0` (precautionary, not an observed failure).
- **Floating `:latest` tag goes stale silently.** `devcontainer up` never
  passes `--pull` even with `--build-no-cache` → reuses cached digest. `dc up`
  now `docker pull`s first. Debugging "fix didn't work": compare
  `FROM ...@sha256:` digest in rebuild log vs latest published digest.
- `dotagents` (`.devcontainer/agents.toml`) only resolves bare `name` +
  `source = "owner/repo"` against `skills/<name>/` subdir — root-level skill
  dir needs explicit `path`. YAML parser also rejects unquoted
  `description:` with mid-string `: ` — quote it. (Hit migrating
  `github-issue` → `Sadotu/agent-skills`.)
- `dotagents-install.sh --upgrade` (every `dc up`) can rewrite
  `agents.lock` pins, leaving primary worktree dirty — worktree-warden
  refuses to fast-forward `main` while dirty and never retries, so a
  routine bump silently wedged it (#79). Fix: `setup-agents.sh` never
  commits the bump onto primary `main`; instead copies the new
  `agents.lock` into a throwaway worktree, commits/pushes on
  `agent/agents-lock-upgrade-<timestamp>`, opens a PR for human review,
  restores primary's tracked copy clean. Always prints a WARNING with the
  PR URL (success or failure), never silent.
- Bitwarden auto-login: GitHub App key, Claude OAuth, Codex auth all need
  vault unlocked but only ONE unlock — shared idempotent
  `ensure_bw_session` (`fatal` for App key, `besteffort` for the two seeds).
  Don't gate a seed on `BW_SESSION` directly — original bug: seed only ran
  inside the App-key-missing branch, so rebuilds with App key already
  present never unlocked vault, seeds silently no-op'd.
- Claude OAuth token persisted to `~/.claude/oauth-env` (chmod 600,
  persisted volume), sourced from `.bashrc` (in-script `export` alone dies
  with setup process). Rotating token in Bitwarden does NOT auto-propagate —
  seed skips if file exists (keeps rebuilds headless). Force re-fetch:
  delete `~/.claude/oauth-env` or `dc wipe-volumes`. Codex auth self-renews,
  no action needed.
- issue-orchestrator self-updates every `dc up` via
  `@nickysagan/issue-orchestrator@latest` from npmjs → `~/.npm-global`
  (shadows Dockerfile-baked fallback). Traps:
  - Name is `@nickysagan/issue-orchestrator` — not bare `issue-orchestrator`,
    not `@sadotu/...`. Wrong name 404s and falls back silently (#39).
  - On npmjs, not GitHub Packages, deliberately — GitHub Packages rejects
    App tokens for reads (`403 Permission installation not allowed`) even
    though `npm whoami` succeeds. **Whoami success ≠ read works** — test an
    actual read. npmjs needs no credential.
  - Never run `issue-orchestrator --version` — no flags supported, any arg
    starts the daemon. Get version from `npm list -g`.
  - Kept as separate `npm install -g` call from claude/codex's — one
    unreachable package aborts the whole command atomically, would silently
    stop claude/codex updating too (confirmed: two-package install with one
    bad name → nothing installs, exit 1).
- worktree-warden (#63) autostarts via `postStartCommand`
  (`start-worktree-warden.sh`), same npm+fallback pattern, runs in detached
  tmux session `worktree-warden`. Same version-probe trap as
  issue-orchestrator — never invoke bare binary to check version, use
  `npm list -g`. State under `<git-common-dir>/worktree-warden/`;
  `state.json` drives the `Worktree Warden: PR #<n> / issue #<n> failed —
  <status>: <reason>` line shown on new shells / `start work`. No auto-retry
  — stays until manually resolved.
- Claude Connectors are account-level (ride `CLAUDE_CODE_OAUTH_TOKEN`), not
  project-scoped — a host GitHub connector would let agents push/PR as
  *you*, not the App. `setup-agents.sh` denies `mcp__github__*` in
  `~/.claude/settings.json` (every run) and strips
  `[mcp_servers.*github*]` from Codex `config.toml`. Needs `dc up`, baked
  into image.
- Sentinel pause/resume (#78): two-package protocol — Sentinel (>=
  `300c65c0`) flips a managed-container lease to `pause_pending`, waits up
  to 30s for `POST /managed-containers/:id/acknowledge` before pausing;
  `@nickysagan/issue-orchestrator` >= 0.2.0 prints the pre-pause message,
  flushes it, acknowledges, then prints the resume message when the lease
  returns to `running`. **Live end-to-end smoke test can't run from inside
  the project container**: no docker socket is mounted (`dc-sentinel.test.sh`
  forbids mounting one), a paused container can't clear its own
  `/_smoke/usage/claude-code` override, and `dc create_sentinel` never sets
  `USAGE_SENTINEL_SMOKE_TOKEN` (endpoint 404s). Force the threshold, watch
  `docker pause`/`unpause`, clear the override from the host.

### GitHub App auth

Use the configured GitHub App for all GitHub CLI issue and PR commands —
never a user PAT, never `gh auth login`. The App ID is `4217970`; the private
key is mounted outside the repo (persisted container volume, fetched from
Bitwarden or dropped in manually — never committed) and must never be
printed or committed.

Before every `gh` command, mint a short-lived token with the baked-in helper:

```bash
GH_TOKEN="$(/opt/agent-devcontainer/gh-app-token.sh)" gh issue list --repo Sadotu/agent-devcontainer
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

Merges and protected-branch pushes are blocked locally: a Claude Code
`PreToolUse` hook (`.devcontainer/deny-merge.sh`) refuses `gh pr merge` and
PUT-to-merge API calls, and the pre-push git hook refuses direct pushes to
`main`/`master`/`develop`. There is no server-side branch protection
backstop — these repos live in a free-plan, private-repo GitHub org where
branch protection is unavailable, so the local hooks are the real
enforcement.
