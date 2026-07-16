#!/usr/bin/env bash
# postCreateCommand for the __PROJECT_NAME__ agent devcontainer.
# Idempotent — safe to re-run on every container rebuild.
set -euo pipefail

WORKSPACE="/workspaces/__PROJECT_NAME__"
BASHRC="$HOME/.bashrc"

echo "==> Fixing ownership of persisted config volumes"
# Named volumes are seeded vscode-owned by the Dockerfile (Docker copies the
# image path's ownership into a fresh volume on first mount). runArgs sets
# --security-opt no-new-privileges, which disables sudo entirely at runtime —
# so this can only ever be a no-op safety net, never an actual fix.
sudo chown "$(id -u):$(id -g)" "$HOME/.config" 2>/dev/null || true
sudo chown -R "$(id -u):$(id -g)" \
  "$HOME/.claude" "$HOME/.codex" \
  "$HOME/.config/gh" "$HOME/.history" 2>/dev/null || true

echo "==> Verifying tooling baked into the image"
for cli in claude codex gh git node npm jq rg curl unzip; do
  command -v "$cli" >/dev/null 2>&1 || echo "WARNING: '$cli' not found on PATH"
done

echo "==> Git safety configuration"
git config --global --add safe.directory "$WORKSPACE"
git config --global push.default current
git config --global init.defaultBranch main

# Local branch-protection safety net: a global pre-push hook that refuses
# direct pushes to main/master/develop. This is convenience only — real
# enforcement must be branch protection on the Git server.
# The hook is COPIED (not referenced in place) so it keeps its exec bit
# regardless of Windows-mount permission quirks.
mkdir -p "$HOME/.githooks"
install -m 0755 "$WORKSPACE/.devcontainer/githooks/pre-push" "$HOME/.githooks/pre-push"
git config --global core.hooksPath "$HOME/.githooks"

echo "==> Shell aliases"
if ! grep -q "# --- __PROJECT_NAME__ agent aliases ---" "$BASHRC"; then
  cat >> "$BASHRC" <<'EOF'

# --- __PROJECT_NAME__ agent aliases ---
# Codex uses --sandbox danger-full-access, not workspace-write: Codex's own
# bwrap sandbox needs unprivileged user namespaces, which Docker's default
# seccomp profile blocks (bwrap: "No permissions to create a new namespace").
# The devcontainer itself is already the sandbox boundary (workspace-only
# bind mount, no host creds, no docker socket), so Codex's inner sandbox is
# redundant anyway. Approval gate (on-request) still stands.
alias ccode='claude --permission-mode auto'
alias cx='codex --sandbox danger-full-access --ask-for-approval on-request'
alias cx-auto='codex --sandbox danger-full-access --ask-for-approval never'
EOF
fi

echo "==> Shared skills location"
mkdir -p "$WORKSPACE/.agents/skills"

# --- GitHub App identity (scoped, admin-free push/PR auth) --------------------
# The container authenticates to GitHub as the "container-coding-agent" App via
# short-lived installation tokens minted from its private key. No user PAT, no
# repo-admin token ever lives here. Drop the App's credentials into the persisted
# volume once:
#   /home/vscode/.config/github-app/app-id           (the numeric App ID)
#   /home/vscode/.config/github-app/private-key.pem  (the App's private key)
#
# Then git push / gh use the App automatically via the credential helper below.
# Agents: NEVER run `gh auth login` or `gh auth setup-git` in this container —
# see the "GitHub App auth" section in CLAUDE.md / AGENTS.md.
mkdir -p /home/vscode/.config/github-app
git config --global credential.https://github.com.helper \
  "!$WORKSPACE/.devcontainer/git-credential-github-app.sh"
# ------------------------------------------------------------------------------

echo "==> Updating agent CLIs to latest (non-fatal — offline/rate-limit safe)"
# No sudo: --security-opt no-new-privileges disables it at runtime, and the
# Dockerfile-baked /usr/bin/{claude,codex} live in root-owned /usr, which npm
# can't rewrite even if the files themselves were chowned (rename needs write
# on the containing dir). Install into a vscode-owned prefix instead and put
# it first on PATH — shadows the baked-in fallback rather than replacing it.
mkdir -p "$HOME/.npm-global"
npm config set prefix "$HOME/.npm-global" >/dev/null 2>&1 || true
export PATH="$HOME/.npm-global/bin:$PATH"
if ! grep -q "# --- __PROJECT_NAME__ npm-global PATH ---" "$BASHRC"; then
  cat >> "$BASHRC" <<'EOF'

# --- __PROJECT_NAME__ npm-global PATH ---
export PATH="$HOME/.npm-global/bin:$PATH"
EOF
fi
if npm install -g @anthropic-ai/claude-code@latest @openai/codex@latest \
    >/tmp/agent-cli-update.log 2>&1; then
  echo "    claude: $(claude --version 2>/dev/null || echo unknown)"
  echo "    codex:  $(codex --version 2>/dev/null || echo unknown)"
else
  echo "WARNING: agent CLI update failed — keeping baked-in versions."
  echo "         See /tmp/agent-cli-update.log for details."
fi

echo "==> Claude Code plugins/skills"
# `claude plugin marketplace add` / `claude plugin install` are safe to re-run —
# an already-added marketplace or already-installed plugin just no-ops.
claude plugin marketplace add obra/superpowers-marketplace 2>&1 | sed 's/^/    /' || true
claude plugin install superpowers@superpowers-marketplace 2>&1 | sed 's/^/    /' || true
claude plugin marketplace add JuliusBrussee/caveman 2>&1 | sed 's/^/    /' || true
claude plugin install caveman@caveman 2>&1 | sed 's/^/    /' || true

mkdir -p "$HOME/.claude/skills"
if [ -d "$WORKSPACE/.agents/skills/github-issue" ] && [ ! -e "$HOME/.claude/skills/github-issue" ]; then
  ln -s "$WORKSPACE/.agents/skills/github-issue" "$HOME/.claude/skills/github-issue"
  echo "    symlinked github-issue skill into ~/.claude/skills/"
fi

echo "==> Codex plugins/skills"
# Codex reserves the marketplace name "openai-curated" (what openai/plugins'
# own manifest declares) and refuses it headlessly. Work around it by copying
# just the superpowers plugin into a local marketplace dir under a different
# name. Manifest path/shape: <root>/.agents/plugins/marketplace.json, plugin
# content under <root>/plugins/<name>/.
CODEX_SP_DIR="$HOME/.codex/marketplaces/superpowers-curated"
if [ ! -d "$CODEX_SP_DIR" ]; then
  tmp_clone="$(mktemp -d)"
  if git clone --depth 1 https://github.com/openai/plugins "$tmp_clone" \
      >/tmp/codex-superpowers-clone.log 2>&1; then
    mkdir -p "$CODEX_SP_DIR/plugins/superpowers" "$CODEX_SP_DIR/.agents/plugins"
    cp -r "$tmp_clone/plugins/superpowers/." "$CODEX_SP_DIR/plugins/superpowers/"
    cat > "$CODEX_SP_DIR/.agents/plugins/marketplace.json" <<'JSON'
{
  "name": "superpowers-curated",
  "interface": { "displayName": "Superpowers (official plugin, local marketplace)" },
  "plugins": [
    {
      "name": "superpowers",
      "source": { "source": "local", "path": "./plugins/superpowers" },
      "policy": { "installation": "AVAILABLE", "authentication": "ON_INSTALL", "products": ["CODEX"] },
      "category": "Developer Tools"
    }
  ]
}
JSON
  else
    echo "WARNING: failed to clone openai/plugins for Codex superpowers."
    echo "         See /tmp/codex-superpowers-clone.log for details."
  fi
  rm -rf "$tmp_clone"
fi
if [ -f "$CODEX_SP_DIR/.agents/plugins/marketplace.json" ]; then
  codex plugin marketplace add "$CODEX_SP_DIR" 2>&1 | sed 's/^/    /' || true
  codex plugin add superpowers@superpowers-curated 2>&1 | sed 's/^/    /' || true
fi

# Caveman for Codex: the skill files already live in .agents/skills/caveman*
# (Codex reads .agents/skills/ natively) and the always-on activation rule is
# already in AGENTS.md. Verify only — no plugin install needed.
if [ -d "$WORKSPACE/.agents/skills/caveman" ] && grep -qi "caveman" "$WORKSPACE/AGENTS.md" 2>/dev/null; then
  echo "    caveman skill + AGENTS.md activation rule present for Codex."
else
  echo "WARNING: caveman skill or AGENTS.md activation rule missing — check"
  echo "         $WORKSPACE/.agents/skills/caveman and $WORKSPACE/AGENTS.md"
fi

echo "==> Done."
echo ""
echo "=== Manual checklist (not scriptable) ==="
echo "1. Claude Code auth: browser '/login' does NOT work in this container."
echo "   On your HOST: run 'claude setup-token', export the result as"
echo "   CLAUDE_CODE_OAUTH_TOKEN before 'dc up' (devcontainer.json forwards it"
echo "   in). Persist it in your host shell profile so rebuilds don't need"
echo "   re-entry. See README.md."
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "   -> CLAUDE_CODE_OAUTH_TOKEN detected, already preconfigured this run."
fi
echo "2. GitHub App credentials: only needed once, and only after a 'dc nuke'"
echo "   (a plain rebuild keeps them). Drop into the persisted volume:"
echo "     printf '%s\n' '<APP_ID>' > ~/.config/github-app/app-id"
echo "     cp /path/to/private-key.pem ~/.config/github-app/private-key.pem"
echo "     chmod 600 ~/.config/github-app/private-key.pem"
echo "   The private key lives at ./secrets/ in this repo on the host (gitignored)."
echo "3. Codex CLI auth: run 'codex' once, follow its ChatGPT/API-key login."
echo "4. Do NOT run 'gh auth login' or 'gh auth setup-git' — this container"
echo "   uses the GitHub App exclusively (see 'GitHub App auth' in CLAUDE.md"
echo "   / AGENTS.md). 'gh'/'git push' work automatically once step 2 is done."
