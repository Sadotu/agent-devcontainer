# agent-devcontainer-template

Template for the secure Claude Code / Codex devcontainer used across many projects. Not an app i tself — clone this to bootstrap a new project's `.devcontainer/`, skills, and instruction files.

## Using this template

```bash
git clone git@github.com:Sadotu/agent-devcontainer-template.git
cd agent-devcontainer-template
./scaffold.sh <project-name> ../<project-name> [gh-owner] [app-id]
```

This copies every file (except `scaffold.sh`, `.git/`, `secrets/`) into
`<target-dir>`, substituting `__PROJECT_NAME__`, `__GH_OWNER__` (default
`Sadotu`), and `__APP_ID__` (default `4217970` — the shared
`container-coding-agent` GitHub App; pass a different one if the new project
uses its own App). See `scaffold.sh` for the remaining manual steps it
prints (git init, secrets/, remote, first push).

Everything below documents the devcontainer itself, as it will read once
instantiated into a real project.

## Security model

The devcontainer bind-mounts **only this repo** to
`/workspaces/__PROJECT_NAME__`. It has:

- ❌ no host home directory, `~/.ssh`, cloud credentials, browser profiles,
  password stores, or Docker socket
- ✅ internet access (package installs, docs lookup)
- ✅ persistent, container-side named volumes for agent auth
  (`~/.claude`, `~/.codex`, `~/.config/gh`, `~/.config/github-app`) —
  tokens/keys are entered manually after first start, survive rebuilds, and
  never touch the host or the repo
- ✅ repo access via a scoped **GitHub App**, not a user PAT — the container
  only ever holds the App's private key and mints short-lived (~1h)
  installation tokens on demand (see
  [Repository access](#repository-access-github-app))

Agents may modify anything in this repo. Nothing outside the mount exists
for them.

## Open / rebuild the devcontainer

### CLI-first (no VS Code) — recommended

Prerequisites (host / WSL):

1. **Docker daemon reachable.** Docker Desktop → Settings → Resources → WSL
   Integration → enable for this distro. Verify: `docker ps` works.
2. **devcontainer CLI**: `npm i -g @devcontainers/cli`.

Then use the `dc` wrapper (`.devcontainer/dc`):

```bash
./.devcontainer/dc up        # build image + start container (runs setup-agents.sh)
./.devcontainer/dc shell     # interactive bash inside the container
./.devcontainer/dc exec ...  # run one command inside, e.g. dc exec claude --version
./.devcontainer/dc rebuild   # rebuild from scratch (after Dockerfile changes)
./.devcontainer/dc down      # stop + remove container (agent config/auth volumes kept)
./.devcontainer/dc nuke      # stop + remove container (agent config/auth volumes kept)
./.devcontainer/dc wipe-volumes --yes  # delete persisted agent config/auth volumes (destructive)
```

`up` then `shell` = you're in. Run `claude`, `codex` from that shell.

### VS Code (optional alternative)

If you ever want the GUI: install the **Dev Containers** extension →
`F1` → **Dev Containers: Reopen in Container**. Same `devcontainer.json`,
same result.

## Authenticate (one time, inside the container)

Tokens are entered manually and stored in container volumes — never commit them.

| Tool | Command | Notes |
|------|---------|-------|
| GitHub (git + `gh`) | drop the App key into `~/.config/github-app/` (once) | Automatic thereafter — see [Repository access](#repository-access-github-app) |
| Claude Code | `claude` | Browser OAuth login fails in this container — see below |
| Codex CLI | `codex` | First run prompts for ChatGPT login or API key |

### Claude Code auth (headless container gotcha)

`claude`'s `/login` browser flow needs a localhost OAuth callback, which
can't reach the container's network namespace. It'll say "Login successful"
but the token never persists (`Not logged in` again on next run). Use a
long-lived token instead:

1. On your **host** machine (anywhere with a real browser): `claude setup-token`
   → copy the printed token (valid ~1 year).
2. Set it as `CLAUDE_CODE_OAUTH_TOKEN` in your host shell **before** running
   `./.devcontainer/dc up` — `devcontainer.json` forwards it in via
   `${localEnv:CLAUDE_CODE_OAUTH_TOKEN}`. Persist it in your host shell
   profile so rebuilds don't need re-entry.
3. If it's already running, `export CLAUDE_CODE_OAUTH_TOKEN=<token>` inside
   the container shell works too, but won't survive a rebuild.

## Repository access (GitHub App)

The container authenticates to GitHub as the **`container-coding-agent`
GitHub App**, not as you and not via a personal access token. The only
secret present is the App's private key; everything else is a short-lived,
auto-minted token.

### How it works

- **The App is installed** on `__GH_OWNER__/__PROJECT_NAME__` with the minimum
  scopes agents need: **Contents**, **Pull requests**, and **Issues**
  (Read and write), **Metadata** (read, automatic).
- **The private key lives in a persisted volume**, dropped in once (see setup
  below):

  | File | Contents |
  |------|----------|
  | `~/.config/github-app/app-id` | the numeric App ID |
  | `~/.config/github-app/private-key.pem` | the App's private key (`.pem`) |

  This is the `__PROJECT_NAME__-github-app-config` volume — it survives
  rebuilds and never touches the host or the repo. On the host, the same key
  lives at `./secrets/` (gitignored — never committed).
- **`.devcontainer/gh-app-token.sh`** builds an RS256-signed App JWT from that
  key, resolves the App's installation on the target repo, and exchanges it
  for a **~1h installation access token**. Tokens are cached in the volume
  and transparently re-minted when stale (>5 min of life reused).
- **`git push` / `git fetch` just work.** `setup-agents.sh` wires
  `.devcontainer/git-credential-github-app.sh` as git's credential helper for
  `https://github.com`, so git asks it for `x-access-token` + a fresh App
  token on every authenticated call. No `gh auth setup-git`, no stored password.
- **`gh` needs the token in its environment**, prefixed explicitly (an
  agent's tool calls are non-interactive):

  ```bash
  GH_TOKEN="$(/workspaces/__PROJECT_NAME__/.devcontainer/gh-app-token.sh)" gh issue list --repo __GH_OWNER__/__PROJECT_NAME__
  ```

### One-time setup

1. Confirm the `container-coding-agent` GitHub App is installed on this repo
   with the scopes above.
2. Inside the container, drop the two credential files into the volume:
   ```bash
   printf '%s\n' '<APP_ID>' > ~/.config/github-app/app-id
   cp /path/to/private-key.pem ~/.config/github-app/private-key.pem
   chmod 600 ~/.config/github-app/private-key.pem
   ```
   The key ships with the repo checkout at `./secrets/*.pem` (gitignored) —
   copy it from there.
3. Verify: `GH_TOKEN="$(/workspaces/__PROJECT_NAME__/.devcontainer/gh-app-token.sh)" gh api /rate_limit`
   should return JSON (not an auth error), and `git fetch` should succeed.
4. Set your git identity for commit authorship (the container has none):
   ```bash
   git config --global user.name  "Your Name"
   git config --global user.email "you@example.com"
   ```

> Override the target repo for a single token mint with
> `GITHUB_APP_REPO=owner/name` (defaults to `__GH_OWNER__/__PROJECT_NAME__`).

## Start an agent

Aliases (installed by `setup-agents.sh`):

| Alias | Expands to | Mode |
|-------|-----------|------|
| `ccode` | `claude --permission-mode auto` | Claude Code, auto mode |
| `cx` | `codex --sandbox danger-full-access --ask-for-approval on-request` | Codex, asks when needed |
| `cx-auto` | `codex --sandbox danger-full-access --ask-for-approval never` | Codex, no prompts |

> `cx`/`cx-auto` use `--sandbox danger-full-access`, not `workspace-write`:
> Codex's own bwrap sandbox needs unprivileged user namespaces, which
> Docker's default seccomp profile blocks (`bwrap: No permissions to create
> a new namespace`). The devcontainer's bind mount is already the sandbox
> boundary, so Codex's inner sandbox added nothing and only broke shell
> commands (`cd`, `grep`, etc). The approval gate (`on-request`) is unaffected.

Each agent reads its instruction file at the repo root: `CLAUDE.md`
(Claude Code), `AGENTS.md` (Codex).

## Skills

Reusable skills live in `.agents/skills/<name>/SKILL.md`. To add one, create
`.agents/skills/<name>/SKILL.md` — see `.agents/skills/README.md` for the
convention. Superpowers and Caveman are installed automatically as Claude
Code/Codex plugins by `.devcontainer/setup-agents.sh` on every container
start. The `github-issue` skill runs the full issue→PR workflow end to end
and is repo-agnostic — it resolves the current repo dynamically rather than
hardcoding one.

## Working on issues safely

1. `git checkout -b agent/<issue-number>-<short-description>`
2. Implement (or point an agent at the issue — see the `github-issue` skill).
3. Test as appropriate for what you built.
4. `git push -u origin agent/<short-description>` — pushing to
   `main`/`master`/`develop` is blocked by a local pre-push hook
   (`.devcontainer/githooks/pre-push`). Real enforcement is GitHub branch
   protection; keep that enabled.
5. `gh pr create --fill` and review the PR before merging.

## Updating agent CLIs

`setup-agents.sh` updates both CLIs to `@latest` automatically on every
container start (non-fatal if offline). To force it without a rebuild:
`sudo npm install -g @anthropic-ai/claude-code@latest @openai/codex@latest`.

## After a rebuild

Most things persist automatically (`~/.claude`, `~/.codex`, GitHub App key,
shell history — all in named volumes that `dc rebuild`, `dc down`, and
`dc nuke` do not touch). `setup-agents.sh` reruns on every start and handles
CLI updates + plugin/skill installs itself. What's left only after
`dc wipe-volumes --yes` or truly first run:

1. **Claude Code auth** — on your host, `claude setup-token`, export
   `CLAUDE_CODE_OAUTH_TOKEN` before `dc up` (see above).
2. **GitHub App key** — drop `app-id` + `private-key.pem` into
   `~/.config/github-app/` (see [Repository access](#repository-access-github-app)).
3. **Codex CLI auth** — run `codex` once, follow its login prompt.

Never `gh auth login` / `gh auth setup-git` — this container is
GitHub-App-only.
