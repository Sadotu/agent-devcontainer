# agent-devcontainer
Secure, reusable Docker devcontainer for Claude Code and Codex workers.

## Prerequisites

- Docker with a reachable daemon (`docker ps` works).
- Dev Container CLI: `npm i -g @devcontainers/cli`.
- The `container-coding-agent` GitHub App installed on your project repository.
- Claude and Codex worker credentials (see below).

## Create project files

From your project directory, pull the image and scaffold `.devcontainer/dc` and
`.devcontainer/devcontainer.json`:

```bash
docker pull ghcr.io/sadotu/agent-devcontainer:latest
docker run --rm -it -v "$PWD":/out ghcr.io/sadotu/agent-devcontainer init
```

The scaffold prompts for project name, GitHub owner, and App ID; keep generated files in your project repository.

## One-time credentials

Create one Bitwarden vault item with custom text fields `app-id` (numeric
GitHub App ID) and `private-key-b64` (base64-encoded private key, for example
`base64 -w0 private-key.pem`). On first start, Bitwarden unlock supplies the
GitHub App key; no `.pem` is written to the host.

Claude workers need `CLAUDE_CODE_OAUTH_TOKEN` exported before `./.devcontainer/dc up` (create
it with `claude setup-token`), or a Bitwarden item named
`claude-code-oauth-token` containing the token in Notes. Codex workers need
Bitwarden item `codex-auth-token` with `~/.codex/auth.json` in Notes. To repair,
inside the container run `codex login --device-auth`, exit, then on the host run
`./.devcontainer/dc codex-push`.

## Daily use

```bash
./.devcontainer/dc up      # pulls image, recreates container from a clean build
./.devcontainer/dc shell
start work
```
Common commands:

```bash
./.devcontainer/dc exec <command>  # one-off command in container
./.devcontainer/dc setup            # retry credentials/setup
./.devcontainer/dc down             # stop/remove container; volumes remain
./.devcontainer/dc codex-push       # container auth -> Bitwarden + host
./.devcontainer/dc codex-pull --force # Bitwarden auth -> container + host
./.devcontainer/test-all.sh [IMAGE_TAG] # run all suites; omit tag for source-only
```

Security boundary: only project repository is bind-mounted at `/workspaces/<project-name>`;
host home, SSH keys, cloud credentials, browser profiles, password stores, and Docker socket
are not mounted. Agent and App credentials persist in container-side named volumes. Inside container, use `ghx` for GitHub CLI;
never run `gh auth login` or `gh auth setup-git`. Worktree Warden autostarts one watcher per repository; an unresolved cleanup failure shows up in new shells, `start work`, and `worktree-warden status`. `dc` and `devcontainer.json` are project files a newer image never rewrites, so `dc up` reconciles them: it warns when `dc` drifts from the image's canonical copy (`dc self-update` applies it), and adds Warden's `postStartCommand` hook to `devcontainer.json` when the project predates it — commit what `up` changes, and where it warns instead of editing (the project sets its own `postStartCommand`, or has no `postCreateCommand` line to anchor to) apply the printed line by hand.
