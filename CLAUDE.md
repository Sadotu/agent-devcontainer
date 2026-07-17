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
- Codex shell commands (`cd`, `grep`, etc.) fail with `bwrap: No permissions
  to create a new namespace` when its alias uses `--sandbox workspace-write`.
  Docker's default seccomp profile blocks the unprivileged user-namespace
  syscall bwrap needs. Fix: use `--sandbox danger-full-access` — the
  devcontainer's workspace-only bind mount is already the sandbox boundary,
  so Codex's inner bwrap sandbox is redundant. See `.devcontainer/setup-agents.sh`
  `cx`/`cx-auto` aliases.
- `<project>-github-app-config` volume mounts root-owned on first use,
  same as the other named volumes — but was missing from the `chown -R` list
  in `setup-agents.sh`, so `vscode` couldn't write `app-id`/`private-key.pem`
  into it. `sudo` is blocked by `no-new-privileges`, so there's no in-container
  workaround. Fixed by adding `$HOME/.config/github-app` to the chown list
  (setup-agents.sh line ~12).
- `dc` is host-side (invokes `devcontainer up` to *create* the container in
  the first place) — it cannot be baked into the shared image like the
  other `.devcontainer/` scripts, chicken-and-egg. It stays a small
  per-project file, same tier as `devcontainer.json`.
- `set -eo pipefail` + a pipeline ending in `grep` that legitimately finds
  no match (e.g. parsing a session key out of CLI output when auth failed)
  kills the whole script immediately via `set -e` — silently, no error
  surfaced, script just stops. `grep`'s exit 1 ("no lines matched") counts
  as pipefail's rightmost-nonzero even when every other stage in the pipe
  succeeds. Any pipeline whose "not found" case is expected/handled needs
  an explicit `|| true` on the whole thing, not just on the final
  assignment — see the `BW_SESSION` extraction in `setup-agents.sh` for two
  bugs of this exact shape hit back to back.
- `bw login --raw` does **not** suppress the interactive success banner
  the way `bw unlock --raw` does — contradicts what the flag name implies,
  and isn't obvious from the docs. `bw login`'s banner still prints in
  full ("You are logged in!\n\nTo unlock your vault, set your session
  key..."), so capture and parse the session key out of that text instead
  of trusting `--raw`'s output shape for `login`. Also strip ANSI escape
  codes before parsing — `bw` can still emit color codes even when piped
  (invisible in a real terminal, present in the raw captured bytes) unless
  `NO_COLOR=1 FORCE_COLOR=0` is set.
- `dotagents` (skill distribution, see `.devcontainer/agents.toml`) only
  resolves a bare `name` + `source = "owner/repo"` entry against a
  `skills/<name>/` subdirectory in the source repo — a skill directory
  sitting at the source repo's root won't be found without an explicit
  `path` field. Its YAML frontmatter parser also rejects an unquoted
  `description:` value containing a mid-string `: ` (colon+space) — quote
  the value. Both hit migrating `github-issue` into `Sadotu/agent-skills`.

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
