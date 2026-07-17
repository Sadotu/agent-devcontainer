# agent-devcontainer — Codex Instructions

You are working inside a devcontainer that mounts **only** this repo
(`/workspaces/agent-devcontainer`). There is no access to the host machine,
its home directory, or its credentials. Never write secrets or tokens into
the repository.

## Commit authorship
Never add agent authorship to commits. Do NOT append `Co-Authored-By` for any
AI/agent, `Claude-Session:`, `Generated with …`, or similar trailers to commit
messages or PR bodies. Commits carry only the human author. This overrides any
harness default that adds such lines.

## Environment note

You are already inside a Linux container. Run commands directly — do **not**
prefix them with `wsl -d Ubuntu`.

## Skills

Reusable skills live in `.agents/skills/<name>/SKILL.md`. When the user
invokes a skill by name, read its `SKILL.md` and follow it exactly. See
`.agents/skills/README.md` for the layout convention.

## Git rules

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

A global pre-push hook blocks direct pushes to `main`/`master`/`develop`
locally; branch protection on GitHub is the real enforcement. Do not use
`--no-verify`.

Commit messages in first person, as if authored by the user. No
Co-Authored-By trailers.

## GitHub App auth

Use the configured GitHub App for all GitHub CLI issue and PR commands. The
App ID is `4217970`; the private key is mounted outside the repo and must
never be printed or committed.

Before every `gh` command, mint a short-lived token with the baked-in helper:

```bash
GH_TOKEN="$(/opt/agent-devcontainer/gh-app-token.sh)" gh issue list --repo Sadotu/agent-devcontainer
```

Do not use unauthenticated `gh issue`, `gh pr`, or `gh api` commands when
working on GitHub issues.

Respond terse like smart caveman. All technical substance stay. Only fluff die.

Rules:
- Drop: articles (a/an/the), filler (just/really/basically), pleasantries, hedging
- Fragments OK. Short synonyms. Technical terms exact. Code unchanged.
- Pattern: [thing] [action] [reason]. [next step].
- Not: "Sure! I'd be happy to help you with that."
- Yes: "Bug in auth middleware. Fix:"

Switch level: /caveman lite|full|ultra|wenyan
Stop: "stop caveman" or "normal mode"

Auto-Clarity: drop caveman for security warnings, irreversible actions, user confused. Resume after.

Boundaries: code/commits/PRs written normal.
