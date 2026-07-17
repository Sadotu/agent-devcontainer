# agent-devcontainer

Source of the secure Claude Code / Codex devcontainer image used across many
projects. This repo builds and publishes `ghcr.io/sadotu/agent-devcontainer` —
a project that wants the devcontainer references that image directly, it
doesn't clone or copy this repo's tree.

## Using this in a project

Two small files, added to your **own** project's repo (not a clone of this
one, not a wrapper directory around it):

1. `.devcontainer/dc` — copy verbatim from this repo (host-side helper,
   unmodified, `chmod +x`).
2. `.devcontainer/devcontainer.json` — copy the template below and fill in
   the three placeholders:

   ```json
   {
     "name": "__PROJECT_NAME__-agents",
     "image": "ghcr.io/sadotu/agent-devcontainer:latest",
     "workspaceFolder": "/workspaces/__PROJECT_NAME__",
     "workspaceMount": "source=${localWorkspaceFolder},target=/workspaces/__PROJECT_NAME__,type=bind,consistency=cached",
     "mounts": [
       "source=__PROJECT_NAME__-claude-config,target=/home/vscode/.claude,type=volume",
       "source=__PROJECT_NAME__-codex-config,target=/home/vscode/.codex,type=volume",
       "source=__PROJECT_NAME__-gh-config,target=/home/vscode/.config/gh,type=volume",
       "source=__PROJECT_NAME__-github-app-config,target=/home/vscode/.config/github-app,type=volume",
       "source=__PROJECT_NAME__-shell-history,target=/home/vscode/.history,type=volume"
     ],
     "remoteUser": "vscode",
     "runArgs": ["--init", "--security-opt", "no-new-privileges"],
     "containerEnv": {
       "HISTFILE": "/home/vscode/.history/.bash_history",
       "CLAUDE_CODE_OAUTH_TOKEN": "${localEnv:CLAUDE_CODE_OAUTH_TOKEN}",
       "PROJECT_NAME": "__PROJECT_NAME__",
       "GH_OWNER": "__GH_OWNER__",
       "APP_ID": "__APP_ID__"
     },
     "postCreateCommand": "/opt/agent-devcontainer/setup-agents.sh",
     "customizations": {
       "vscode": { "extensions": ["anthropic.claude-code", "dbaeumer.vscode-eslint"] }
     }
   }
   ```

   Replace `__PROJECT_NAME__` (your repo's name), `__GH_OWNER__` (default
   `Sadotu`), and `__APP_ID__` (default `4217970` — the shared
   `container-coding-agent` GitHub App; use a different one if this project
   has its own App). These are the *only* hand-edited values — everything
   else (Dockerfile, `setup-agents.sh`, skills) lives in the published image
   and updates by pulling a new tag, not by re-copying files.

Then wire up GitHub App credentials — with Bitwarden this is a one-time
`BW_GITHUB_APP_ITEM_ID` in `devcontainer.json` and the key is fetched
automatically on first start (no `.pem` ever on host disk); without it, drop
the key in manually. See [Repository access](#repository-access-github-app)
for both. Then `./.devcontainer/dc up`.

`CLAUDE.md`/`AGENTS.md` are still worth writing per-project (they're your
project's own instructions, not something to templatize), but nothing about
the devcontainer itself needs copying beyond the two files above.

## Security model

The devcontainer bind-mounts **only the project repo** to
`/workspaces/<project-name>`. It has:

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
./.devcontainer/dc up        # pull image + start container (runs setup-agents.sh)
./.devcontainer/dc shell     # interactive bash inside the container
./.devcontainer/dc exec ...  # run one command inside, e.g. dc exec claude --version
./.devcontainer/dc rebuild   # recreate the container, re-pulling the image
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

Credentials are fetched from Bitwarden if configured, or entered manually,
and stored in container volumes — never commit them.

| Tool | Command | Notes |
|------|---------|-------|
| GitHub (git + `gh`) | Bitwarden: unlock once at first start (key fetched automatically). Manual: drop the App key into `~/.config/github-app/` once | Automatic thereafter — see [Repository access](#repository-access-github-app) |
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

Alternatively, store the token in a Bitwarden item's **notes** and set
`BW_CLAUDE_TOKEN_ITEM_ID=<item-id>` in `devcontainer.json`'s `containerEnv`.
When `CLAUDE_CODE_OAUTH_TOKEN` isn't already forwarded from the host,
`setup-agents.sh` fetches it from that item during the same Bitwarden unlock it
uses for the GitHub App key — no host-side env needed. This fetch only fires
when that unlock runs (i.e. when the GitHub App key isn't yet in its volume);
once `claude` has logged in, the login state itself persists in the `~/.claude`
volume across rebuilds.

## Repository access (GitHub App)

The container authenticates to GitHub as the **`container-coding-agent`
GitHub App**, not as you and not via a personal access token. The only
secret present is the App's private key; everything else is a short-lived,
auto-minted token.

### How it works

- **The App is installed** on `__GH_OWNER__/__PROJECT_NAME__` with the minimum
  scopes agents need: **Contents**, **Pull requests**, and **Issues**
  (Read and write), **Metadata** (read, automatic).
- **The private key lives in a persisted volume**, populated once at first
  start — automatically from Bitwarden if configured, or dropped in manually
  (see setup below):

  | File | Contents |
  |------|----------|
  | `~/.config/github-app/app-id` | the numeric App ID |
  | `~/.config/github-app/private-key.pem` | the App's private key (`.pem`) |

  This is the `__PROJECT_NAME__-github-app-config` volume — it survives
  rebuilds and never touches the host or the repo. Fetched from Bitwarden or
  dropped in manually — see [One-time setup](#one-time-setup) below.
- **`/opt/agent-devcontainer/gh-app-token.sh`** (baked into the image) builds
  an RS256-signed App JWT from that key, resolves the App's installation on
  the target repo, and exchanges it for a **~1h installation access token**.
  Tokens are cached in the volume and transparently re-minted when stale
  (>5 min of life reused).
- **`git push` / `git fetch` just work.** `setup-agents.sh` wires
  `/opt/agent-devcontainer/git-credential-github-app.sh` as git's credential
  helper for `https://github.com`, so git asks it for `x-access-token` + a
  fresh App token on every authenticated call. No `gh auth setup-git`, no
  stored password.
- **`gh` needs the token in its environment**, prefixed explicitly (an
  agent's tool calls are non-interactive):

  ```bash
  GH_TOKEN="$(/opt/agent-devcontainer/gh-app-token.sh)" gh issue list --repo __GH_OWNER__/__PROJECT_NAME__
  ```

### One-time setup

1. Confirm the `container-coding-agent` GitHub App is installed on this repo
   with the scopes above.
2. Get the credential files into the volume, one of two ways:
   - **Bitwarden (recommended, works on any machine you're logged into
     Bitwarden on)**: on one vault item, add two custom text fields —
     `app-id` (the numeric App ID) and `private-key-b64` (the private key,
     base64-encoded: `base64 -w0 private-key.pem`, paste the output as the
     field value). Custom fields work on the free tier; a file *attachment*
     would need Premium, so this deliberately avoids that. Then set
     `BW_GITHUB_APP_ITEM_ID=<item-id>` in `devcontainer.json`'s
     `containerEnv`. `setup-agents.sh` prompts for `bw unlock` on first start
     of a fresh container and decodes both automatically — no `.pem` ever
     touches host disk outside the vault.
   - **Manual**: `mkdir secrets && cp /path/to/private-key.pem secrets/` on
     the host (gitignored), then inside the container:
     ```bash
     printf '%s\n' '<APP_ID>' > ~/.config/github-app/app-id
     cp /path/to/private-key.pem ~/.config/github-app/private-key.pem
     chmod 600 ~/.config/github-app/private-key.pem
     ```
3. Verify: `GH_TOKEN="$(/opt/agent-devcontainer/gh-app-token.sh)" gh api /rate_limit`
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

Three distribution paths, depending on what the skill is:

- **Superpowers / Caveman** — full Claude Code plugins (slash commands,
  subagents, not just skills). Installed automatically via `claude plugin
  marketplace add` / `install` by `setup-agents.sh` on every container start.
  Caveman also vendors its raw skill files under this repo's own
  `.agents/skills/caveman*` for Codex, which reads `.agents/skills/` natively
  — no plugin needed there.
- **Self-authored skills** (`github-issue`, future ones) — plain `SKILL.md`
  dirs, live in [`Sadotu/agent-skills`](https://github.com/Sadotu/agent-skills),
  distributed to every project via
  [`dotagents`](https://docs.sentry.io/ai/dotagents/) (`npx @sentry/dotagents
  install`, run by `setup-agents.sh` against the `agents.toml` baked into the
  image). Covers both Claude and Codex from one source — no per-repo file
  copy. To add a skill: add a `SKILL.md` dir to `agent-skills`, add an entry
  to `.devcontainer/agents.toml` here, rebuild+push the image.
- **Project-specific skills** — if a skill only matters to one project, just
  put it in that project's own `.agents/skills/`. No need to route it through
  `agent-skills` or this image.

## Working on issues safely

1. `git checkout -b agent/<issue-number>-<short-description>`
2. Implement (or point an agent at the issue — see the `github-issue` skill).
3. Test as appropriate for what you built.
4. `git push -u origin agent/<short-description>` — pushing to
   `main`/`master`/`develop` is blocked by a global pre-push hook
   (`~/.githooks/pre-push`, installed from the image on every container
   start). Real enforcement is GitHub branch protection; keep that enabled.
5. `gh pr create --fill` and review the PR before merging.

## Updating agent CLIs

`setup-agents.sh` updates both CLIs to `@latest` automatically on every
container start (non-fatal if offline). To force it without waiting for the
next start: `npm install -g @anthropic-ai/claude-code@latest
@openai/codex@latest` (no `sudo` — installs into the `vscode`-owned
`~/.npm-global` prefix, which shadows the image's baked-in fallback on
`PATH`; `sudo` is disabled at runtime by `--security-opt no-new-privileges`
anyway).

## After a rebuild

Most things persist automatically (`~/.claude`, `~/.codex`, GitHub App key,
shell history — all in named volumes that `dc rebuild`, `dc down`, and
`dc nuke` do not touch). `setup-agents.sh` reruns on every start and handles
CLI updates + plugin/skill installs itself. What's left only after
`dc wipe-volumes --yes` or truly first run:

1. **Claude Code auth** — on your host, `claude setup-token`, export
   `CLAUDE_CODE_OAUTH_TOKEN` before `dc up` (see above).
2. **GitHub App key** — with `BW_GITHUB_APP_ITEM_ID` set, just unlock
   Bitwarden once when prompted and the key is fetched automatically;
   otherwise drop `app-id` + `private-key.pem` into `~/.config/github-app/`
   manually (see [Repository access](#repository-access-github-app)).
3. **Codex CLI auth** — run `codex` once, follow its login prompt.

Never `gh auth login` / `gh auth setup-git` — this container is
GitHub-App-only.

## Maintaining this repo (image source)

This repo's own `.devcontainer/devcontainer.json` uses `build`, not `image`
— unlike a consumer project, it needs to actually build the Dockerfile
locally to test changes before publishing. Workflow:

1. Edit `Dockerfile` / `setup-agents.sh` / `gh-app-token.sh` /
   `git-credential-github-app.sh` / `githooks/pre-push` / `agents.toml`.
2. `./.devcontainer/dc rebuild` — builds and starts against this repo's own
   dogfood volumes (`agent-devcontainer-dev-*`), isolated from any real
   project's containers.
3. Verify inside: `claude --version`, `codex --version`,
   `/opt/agent-devcontainer/gh-app-token.sh` (needs this repo's own App
   credentials set up per [Repository access](#repository-access-github-app)
   if you want to test that path), `dotagents install` picks up
   `agent-skills`.
4. Push to `main` (via PR). `.github/workflows/publish-image.yml` builds and
   pushes `ghcr.io/sadotu/agent-devcontainer:latest` +
   `:<commit-sha>` automatically, using the workflow's own `GITHUB_TOKEN` —
   no PAT involved. Existing projects pick up the change on their next
   `dc rebuild` / "Rebuild Container".
5. **First publish only**: the pushed package defaults to private on
   ghcr.io — go to the package's settings on GitHub and set it public, or
   every consumer machine will additionally need `docker login ghcr.io`.

`dotagents`-managed skills (`Sadotu/agent-skills`) update independently of
the image — edit that repo directly, no rebuild/publish needed here; the
next `setup-agents.sh` run on any project picks it up.
