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
  the first place), so at *runtime* it can't be one of the image-baked
  `.devcontainer/` scripts — it has to already exist in the project repo
  before any image is pulled. It's still a per-project file, same tier as
  `devcontainer.json`. It IS, however, baked into the image as a *template*
  (`/opt/agent-devcontainer/templates/dc`) that the `init` scaffolder emits
  into a new project — that makes the image the single source of truth and
  kills the old "copy `dc` verbatim" drift, without changing that `dc` runs
  host-side. `dc` is project-agnostic (derives PROJECT_NAME from the repo
  dir name), so the baked template is byte-identical to what every project
  gets.
- The `init` scaffolder (`/usr/local/bin/init`, run via `docker run --rm -it
  -v "$PWD":/out ghcr.io/sadotu/agent-devcontainer init`) is a normal script
  on PATH, deliberately NOT an `ENTRYPOINT`. The devcontainer lifecycle
  (`devcontainer up` sets its own container command) is the source of most
  past pain here (stale images, ownership, sudo) — an entrypoint dispatcher
  would have put init logic in that critical path for no benefit. `docker
  run IMAGE init` resolves `init` via PATH instead, leaving container start
  completely untouched. It also can't produce the project files from
  *inside* the devcontainer lifecycle (postCreate runs too late — the files
  it would write are the ones needed to start the container), which is why
  it's a separate `docker run`, not a postCreate step.
- `set -eo pipefail` + a pipeline ending in `grep` that legitimately finds
  no match (e.g. parsing a session key out of CLI output when auth failed)
  kills the whole script immediately via `set -e` — silently, no error
  surfaced, script just stops. `grep`'s exit 1 ("no lines matched") counts
  as pipefail's rightmost-nonzero even when every other stage in the pipe
  succeeds. Any pipeline whose "not found" case is expected/handled needs
  an explicit `|| true` on the whole thing, not just on the final
  assignment — see the `BW_SESSION` extraction in `setup-agents.sh` for two
  bugs of this exact shape hit back to back.
- A plain `bw login` (no `--raw`) already unlocks the vault and prints the
  session key inside its success banner ("You are logged in!\n\n...export
  BW_SESSION=\"...\"") — chaining a separate `bw unlock` after it just adds
  a second, easy-to-miss master-password prompt. `setup-agents.sh` parses
  the key out of the banner text, which works regardless of `--raw`'s exact
  behavior. (Whether `login --raw` suppresses the banner the way
  `unlock --raw` does was never actually verified — an earlier note here
  claimed it was "confirmed against a real run", but every observed failure
  turned out to be running a stale pre-fix image, so that claim had no
  evidence behind it.) The parser also strips ANSI escape codes and sets
  `NO_COLOR=1 FORCE_COLOR=0` as precautionary hardening — also not an
  observed failure mode, just cheap insurance.
- **A floating image tag (`:latest`) goes stale silently.** `devcontainer
  up` — even with `--remove-existing-container --build-no-cache` — never
  passes `--pull`, so it reuses whatever digest the local Docker cache has
  for the tag. Three rounds of published fixes never reached the machine
  that was testing them; every "still broken" report was the original
  image re-running. `dc up`/`dc rebuild` now `docker pull` the image named
  in `devcontainer.json` first. When debugging "my fix didn't work",
  compare the `FROM ...@sha256:` digest in the rebuild log against the
  latest published digest before assuming the fix is wrong.
- `dotagents` (skill distribution, see `.devcontainer/agents.toml`) only
  resolves a bare `name` + `source = "owner/repo"` entry against a
  `skills/<name>/` subdirectory in the source repo — a skill directory
  sitting at the source repo's root won't be found without an explicit
  `path` field. Its YAML frontmatter parser also rejects an unquoted
  `description:` value containing a mid-string `: ` (colon+space) — quote
  the value. Both hit migrating `github-issue` into `Sadotu/agent-skills`.
- Bitwarden auto-login (`setup-agents.sh`): the GitHub App key, the Claude
  OAuth token, and the Codex auth each need the vault unlocked, but only ONE
  unlock should happen. They call a shared idempotent `ensure_bw_session`
  (`fatal` for the required App key, `besteffort` for the two seeds) —
  DON'T re-inline a per-consumer unlock or gate a seed on `BW_SESSION`. The
  original bug did exactly that: seeds gated on `BW_SESSION`, which was only
  set inside the App-key-missing branch, so on any rebuild where the App key
  was already in its volume the vault never unlocked and both seeds silently
  no-op'd.
- The fetched Claude OAuth token is persisted to `~/.claude/oauth-env`
  (chmod 600, on the persisted `~/.claude` volume) and sourced from
  `.bashrc` — an in-script `export` alone dies with the setup process and
  never reaches the interactive `claude`. Consequence: rotating the token in
  Bitwarden does NOT propagate on the next rebuild, because the seed skips
  when `oauth-env` already exists (that skip is what keeps rebuilds
  headless). To pick up a rotated token, delete `~/.claude/oauth-env` (or
  `dc wipe-volumes`) to force a re-fetch. Codex auth (`~/.codex/auth.json`)
  self-renews via its refresh token, so it doesn't need this.
- Optional tools (`usage-sentinel.sh`): `usage-sentinel`'s `dist/` is
  gitignored upstream, so a fresh clone has NO build output — it must be built
  once (`npm install` pulls only devDeps like `tsc`; there are zero runtime
  deps). The checkout lives on the persisted `<project>-usage-sentinel` volume
  and is skipped once present (headless-rebuild philosophy, like `oauth-env`);
  wipe the volume / `rm -rf ~/.local/share/usage-sentinel/repo` to refresh.
  The service is wired BOTH from `setup-agents.sh` (postCreate — heavy
  clone+build, once) and as `postStartCommand` (fast start-if-not-listening) —
  postCreate does NOT re-run on a plain container restart, only on
  create/rebuild, so the service would otherwise die on restart. The script is
  idempotent and always exits 0 (it's a lifecycle command; a nonzero exit is
  noisy). `tmux` is baked in the Dockerfile, NOT runtime-optional: apt needs
  root and `no-new-privileges` kills `sudo` at runtime.

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
