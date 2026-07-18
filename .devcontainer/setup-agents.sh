#!/usr/bin/env bash
# postCreateCommand for the shared agent devcontainer image. Baked into the
# image at /opt/agent-devcontainer/setup-agents.sh — every project's thin
# devcontainer.json points postCreateCommand here rather than at a
# per-project copy, and supplies PROJECT_NAME/GH_OWNER via containerEnv.
# Idempotent — safe to re-run on every container rebuild.
set -euo pipefail

: "${PROJECT_NAME:?PROJECT_NAME must be set via devcontainer.json containerEnv}"
WORKSPACE="/workspaces/$PROJECT_NAME"
TOOLDIR="/opt/agent-devcontainer"
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
install -m 0755 "$TOOLDIR/githooks/pre-push" "$HOME/.githooks/pre-push"
git config --global core.hooksPath "$HOME/.githooks"

echo "==> Shell aliases"
if ! grep -q "# --- agent-devcontainer aliases ---" "$BASHRC"; then
  cat >> "$BASHRC" <<'EOF'

# --- agent-devcontainer aliases ---
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

# Source the persisted Claude OAuth token into interactive shells. The setup
# script's own `export` dies with its process; this file (written on the
# persisted ~/.claude volume when the token is seeded from Bitwarden) is what
# actually makes `claude` authenticated in the terminal the user runs.
if ! grep -q "# --- agent-devcontainer claude oauth env ---" "$BASHRC"; then
  cat >> "$BASHRC" <<'EOF'

# --- agent-devcontainer claude oauth env ---
[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -r "$HOME/.claude/oauth-env" ] && . "$HOME/.claude/oauth-env"
EOF
fi

echo "==> Shared skills location"
mkdir -p "$WORKSPACE/.agents/skills"

# --- GitHub App identity (scoped, admin-free push/PR auth) --------------------
# The container authenticates to GitHub as the configured App via short-lived
# installation tokens minted from its private key. No user PAT, no repo-admin
# token ever lives here. Credentials land in the persisted volume at:
#   /home/vscode/.config/github-app/app-id           (the numeric App ID)
#   /home/vscode/.config/github-app/private-key.pem  (the App's private key)
# — fetched from Bitwarden below if configured, or dropped in manually
# otherwise (see the manual checklist at the end of this script).
#
# Then git push / gh use the App automatically via the credential helper below.
# Agents: NEVER run `gh auth login` or `gh auth setup-git` in this container —
# see the "GitHub App auth" section in CLAUDE.md / AGENTS.md.
GITHUB_APP_DIR="$HOME/.config/github-app"
mkdir -p "$GITHUB_APP_DIR"
git config --global credential.https://github.com.helper \
  "!$TOOLDIR/git-credential-github-app.sh"
# ------------------------------------------------------------------------------

echo "==> Secrets bootstrap (Bitwarden)"
# GitHub App credentials are REQUIRED — without them no App token can be
# minted, so nothing in this container can push, PR, or use `gh`. If they
# aren't already in the persisted volume (first start, or after `dc
# wipe-volumes`), they MUST come out of Bitwarden here, and failure is
# fatal: better a loud postCreate error than a "working" container whose
# first git push dies with a confusing auth error.
#
# No vault item ID is needed (it can't be known before unlocking anyway —
# chicken-and-egg): after unlock the item is DISCOVERED by its custom
# fields, i.e. the single vault item carrying both an "app-id" and a
# "private-key-b64" text field. BW_GITHUB_APP_ITEM_ID (item *name* or GUID —
# `bw get item` accepts either) remains as an optional override for vaults
# where that discovery is ambiguous.
#
# Uses a base64-encoded custom field, not a Bitwarden attachment: file
# attachments are a Premium-only feature, custom fields work on the free
# tier ("private-key-b64" = private-key.pem run through `base64 -w0`).

# Fatal-error helper: every bw failure path funnels here. Exits nonzero so
# `dc up` surfaces the postCreate failure instead of scrolling past it.
bw_fail() {
  echo "" >&2
  echo "ERROR: $1" >&2
  shift
  local line
  for line in "$@"; do echo "       $line" >&2; done
  echo "" >&2
  echo "       Fix the issue, then re-run setup WITHOUT a rebuild:" >&2
  echo "         ./.devcontainer/dc setup" >&2
  echo "       (Manual fallback — drop the credentials in yourself:" >&2
  echo "        see 'Repository access' in the agent-devcontainer README.)" >&2
  exit 1
}

# Idempotent Bitwarden unlock. Sets the global BW_SESSION (and marks
# bw_unlocked_by_us so the tail can re-lock). Every consumer that needs the
# vault — the GitHub App key, the Claude token, the Codex auth — calls this,
# so the unlock is DECOUPLED from any single consumer. Previously the unlock
# lived inside the "App key missing" branch, so on a rebuild where that key
# was already in its persisted volume the vault was never unlocked and the
# Claude/Codex seeds silently no-op'd.
#
#   ensure_bw_session fatal       — unrecoverable failure aborts via bw_fail
#   ensure_bw_session besteffort  — failure just warns and returns 1
#
# Returns 0 with BW_SESSION set on success.
bw_unlocked_by_us=false
bw_session_announced=false
ensure_bw_session() {
  local mode="$1"
  if [ -n "${BW_SESSION:-}" ]; then
    if [ "$bw_session_announced" != true ]; then
      echo "    Reusing existing BW_SESSION."
      bw_session_announced=true
    fi
    return 0
  fi
  if ! command -v bw >/dev/null 2>&1; then
    [ "$mode" = fatal ] && bw_fail "Bitwarden CLI (bw) not found in the image — cannot fetch the GitHub App key."
    echo "    WARN: Bitwarden CLI (bw) not found — skipping best-effort seed." >&2
    return 1
  fi
  local bw_attempt=1 bw_log
  while :; do
    bw_log="$(mktemp)"
    if NO_COLOR=1 FORCE_COLOR=0 bw login --check >/dev/null 2>&1; then
      # Already logged in (login state persisted from a prior run in this
      # container) — just needs unlocking.
      echo "    Bitwarden already logged in — unlocking (interactive)..."
      NO_COLOR=1 FORCE_COLOR=0 bw unlock 2>&1 | tee "$bw_log" >&2 || true
    else
      # A successful `bw login` already unlocks the vault as part of
      # authenticating — no separate `bw unlock` needed.
      echo "    Logging into Bitwarden (interactive — one-time per container)..."
      NO_COLOR=1 FORCE_COLOR=0 bw login 2>&1 | tee "$bw_log" >&2 || true
    fi
    # Strip ANSI escapes before parsing. `|| true` guards the whole pipeline:
    # under `set -eo pipefail`, grep finding no match (the expected outcome on
    # a failed login) would otherwise kill the script here (see CLAUDE.md).
    BW_SESSION="$(sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$bw_log" \
      | grep -oE 'BW_SESSION="[^"]*"' | head -1 | cut -d'"' -f2 || true)"
    if [ -n "$BW_SESSION" ]; then
      rm -f "$bw_log"
      bw_unlocked_by_us=true
      bw_session_announced=true
      return 0
    fi
    # No session — classify the failure from bw's own output.
    if grep -qiE 'ENOTFOUND|ECONNREFUSED|ETIMEDOUT|EAI_AGAIN|network error|cannot connect|failed to fetch' "$bw_log"; then
      rm -f "$bw_log"
      [ "$mode" = fatal ] && bw_fail "Cannot reach Bitwarden — network problem (see output above)." \
        "Check the container's network / VPN / Bitwarden server status."
      echo "    WARN: cannot reach Bitwarden (network) — skipping best-effort seed." >&2
      return 1
    fi
    if grep -qiE 'incorrect|invalid master password' "$bw_log"; then
      rm -f "$bw_log"
      if [ "$bw_attempt" -ge 3 ]; then
        [ "$mode" = fatal ] && bw_fail "Bitwarden login/unlock failed after 3 attempts (wrong master password?)."
        echo "    WARN: Bitwarden unlock failed (wrong master password) — skipping best-effort seed." >&2
        return 1
      fi
      bw_attempt=$((bw_attempt + 1))
      echo "    Wrong credentials — retrying (attempt $bw_attempt/3)..."
      continue
    fi
    # Neither a session nor a recognizable error: most likely bw never got an
    # interactive terminal to prompt on (e.g. VS Code "Rebuild Container" runs
    # postCreate without stdin). Dump the log for diagnosis.
    echo "    DEBUG: could not find a session key in bw's output — raw log:"
    sed 's/^/    | /' "$bw_log"
    rm -f "$bw_log"
    [ "$mode" = fatal ] && bw_fail "Bitwarden login produced no session and no recognizable error." \
      "If this setup ran non-interactively (VS Code rebuild), run it from" \
      "a terminal instead — that's what 'dc setup' below is for."
    echo "    WARN: Bitwarden not available non-interactively — skipping best-effort seed." >&2
    return 1
  done
}

if [ ! -r "$GITHUB_APP_DIR/private-key.pem" ] || [ ! -r "$GITHUB_APP_DIR/app-id" ]; then
  # The App key is REQUIRED, so unlock is fatal-on-failure here.
  ensure_bw_session fatal

  # --- Item selection: explicit override, or discovery by custom fields ------
  if [ -n "${BW_GITHUB_APP_ITEM_ID:-}" ]; then
    item_json="$(bw get item "$BW_GITHUB_APP_ITEM_ID" --session "$BW_SESSION" 2>/dev/null || true)"
    [ -n "$item_json" ] \
      || bw_fail "BW_GITHUB_APP_ITEM_ID is set ('$BW_GITHUB_APP_ITEM_ID') but matches no unique vault item." \
           "It accepts an item name or GUID; a name must match exactly one item."
  else
    items_json="$(bw list items --session "$BW_SESSION" 2>/dev/null || true)"
    [ -n "$items_json" ] \
      || bw_fail "'bw list items' returned nothing — vault empty, or BW_SESSION stale?" \
           "(If you exported BW_SESSION yourself, unset it and retry.)"
    # `|| bw_fail`: under set -e a jq parse failure (bw emitting non-JSON)
    # would otherwise kill the script here with no message at all — the
    # exact silent-death shape from the CLAUDE.md pipefail gotcha.
    matches="$(printf '%s' "$items_json" | jq \
      '[.[] | select(((.fields // []) | map(.name)) as $n
                     | ($n | index("app-id")) and ($n | index("private-key-b64")))]')" \
      || bw_fail "'bw list items' returned unparseable output (not JSON)."
    match_count="$(printf '%s' "$matches" | jq 'length')"
    case "$match_count" in
      0)
        bw_fail "No vault item found with both 'app-id' and 'private-key-b64' custom fields." \
          "Create one: two custom TEXT fields on a single item —" \
          "  app-id           the numeric GitHub App ID" \
          "  private-key-b64  base64 of the App key (base64 -w0 private-key.pem)"
        ;;
      1)
        item_json="$(printf '%s' "$matches" | jq '.[0]')"
        ;;
      *)
        echo "    Ambiguous — $match_count vault items carry both fields:" >&2
        printf '%s' "$matches" | jq -r '.[] | "      - \(.name)"' >&2
        bw_fail "Multiple vault items match discovery." \
          "Set BW_GITHUB_APP_ITEM_ID (in devcontainer.json containerEnv) to" \
          "one of the names above to disambiguate."
        ;;
    esac
  fi

  # --- Extract, validate, persist -------------------------------------------
  if printf '%s' "$item_json" \
         | jq -r '.fields[] | select(.name=="private-key-b64") | .value' \
         | base64 -d > "$GITHUB_APP_DIR/private-key.pem" 2>/dev/null \
      && printf '%s' "$item_json" \
         | jq -r '.fields[] | select(.name=="app-id") | .value' \
         > "$GITHUB_APP_DIR/app-id" \
      && [ -s "$GITHUB_APP_DIR/private-key.pem" ] && [ -s "$GITHUB_APP_DIR/app-id" ]; then
    # Catch a syntactically-valid base64 blob that isn't actually a key
    # (wrong field contents) before it becomes a cryptic JWT-signing error.
    if command -v openssl >/dev/null 2>&1 \
        && ! openssl pkey -noout -in "$GITHUB_APP_DIR/private-key.pem" >/dev/null 2>&1; then
      rm -f "$GITHUB_APP_DIR/private-key.pem" "$GITHUB_APP_DIR/app-id"
      bw_fail "Fetched 'private-key-b64' does not decode to a valid private key." \
        "Re-create the field with: base64 -w0 private-key.pem"
    fi
    chmod 600 "$GITHUB_APP_DIR/private-key.pem"
    echo "    GitHub App credentials fetched from Bitwarden item: $(printf '%s' "$item_json" | jq -r '.name')"
  else
    rm -f "$GITHUB_APP_DIR/private-key.pem" "$GITHUB_APP_DIR/app-id"
    bw_fail "Vault item found but extracting/decoding its fields failed." \
      "Check that 'app-id' and 'private-key-b64' are custom TEXT fields with" \
      "the right contents (private-key-b64 = base64 -w0 private-key.pem)."
  fi
fi
# --- Claude Code OAuth token (best-effort) -----------------------------------
# Seed the token from Bitwarden so `claude` works headless. Independent of the
# GitHub App fetch above: this calls ensure_bw_session itself, so it seeds even
# on a rebuild where the App key was already in its persisted volume (the old
# code gated on BW_SESSION and silently skipped in that case).
#
# Persistence matters: an in-script `export` dies with this process, so the
# interactive shell — the `claude` the user actually runs — would never see it.
# We write it to $HOME/.claude/oauth-env (on the persisted ~/.claude volume)
# and source that from .bashrc (below). That also makes subsequent rebuilds
# headless: the file is already present, so no master-password re-prompt.
#
# Precedence: a host-forwarded CLAUDE_CODE_OAUTH_TOKEN (devcontainer.json
# localEnv) wins and needs no seeding; an already-persisted oauth-env means
# we're done. Only an empty env AND a missing file triggers a Bitwarden fetch.
#
# Stored as the Notes of a well-known vault item named 'claude-code-oauth-token'
# (Notes body = the `claude setup-token` output). BW_CLAUDE_TOKEN_ITEM_ID
# overrides that item name (accepts a name or GUID).
CLAUDE_OAUTH_ENV="$HOME/.claude/oauth-env"
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ ! -r "$CLAUDE_OAUTH_ENV" ]; then
  if ensure_bw_session besteffort; then
    claude_item="${BW_CLAUDE_TOKEN_ITEM_ID:-claude-code-oauth-token}"
    # `bw get notes` prints only the Notes body; strip newlines so the stored
    # token is exactly the one-line string.
    claude_token="$(bw get notes "$claude_item" --session "$BW_SESSION" 2>/dev/null | tr -d '\r\n' || true)"
    if [ -n "$claude_token" ]; then
      mkdir -p "$HOME/.claude"
      ( umask 077; printf 'export CLAUDE_CODE_OAUTH_TOKEN=%q\n' "$claude_token" > "$CLAUDE_OAUTH_ENV" )
      chmod 600 "$CLAUDE_OAUTH_ENV"
      echo "    CLAUDE_CODE_OAUTH_TOKEN fetched from Bitwarden item '$claude_item' and persisted to ~/.claude/oauth-env."
    else
      echo "    (No '$claude_item' notes in vault — relying on host env or the persisted ~/.claude login.)"
    fi
  fi
fi
# Make the token available to THIS setup process too — the `claude plugin`
# installs further down authenticate with it.
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -r "$CLAUDE_OAUTH_ENV" ]; then
  . "$CLAUDE_OAUTH_ENV"
fi
# Interactive Claude's first-run wizard still demands a login choice even when
# CLAUDE_CODE_OAUTH_TOKEN is set — only headless (-p) mode honors the token
# without onboarding. The wizard's state lives in ~/.claude.json, which sits at
# $HOME root, OUTSIDE the persisted ~/.claude volume, so every rebuild wipes it
# and re-triggers the login screen. Seed the onboarding flag whenever a token
# is present so `claude` boots straight to the main UI, authed via the env var.
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ ! -s "$HOME/.claude.json" ]; then
  printf '{"hasCompletedOnboarding": true}\n' > "$HOME/.claude.json"
  echo "    Seeded ~/.claude.json onboarding flag (skips interactive login wizard)."
fi
# --- Codex CLI auth (best-effort, subscription) ------------------------------
# Same rationale as the Claude token: seed it once from Bitwarden so `codex`
# works headless, with no interactive `codex login --device-auth` step. Codex
# keeps its ChatGPT subscription login in ~/.codex/auth.json (access + refresh
# tokens); once present it auto-refreshes that file in place, and the persisted
# ~/.codex volume carries it across rebuilds. So only seed when the file is
# absent (fresh volume). Like the Claude token, this calls ensure_bw_session
# itself rather than depending on the App fetch having unlocked the vault.
# NOT fatal — if it's missing, `codex login --device-auth` remains the manual
# fallback.
#
# Stored as the Notes of a well-known vault item named 'codex-auth-token'
# (Notes body = a working ~/.codex/auth.json, produced by `codex login` on any
# machine with a browser). Notes, not a custom field: the auth.json is ~4 KB,
# over Bitwarden's 5000-char custom-field limit. BW_CODEX_AUTH_ITEM_ID overrides
# the item name (name or GUID).
CODEX_AUTH="$HOME/.codex/auth.json"
if [ ! -r "$CODEX_AUTH" ] && ensure_bw_session besteffort; then
  codex_item="${BW_CODEX_AUTH_ITEM_ID:-codex-auth-token}"
  codex_notes="$(bw get notes "$codex_item" --session "$BW_SESSION" 2>/dev/null || true)"
  if [ -n "$codex_notes" ]; then
    mkdir -p "$HOME/.codex"
    # Validate it's real Codex auth JSON (carries a refresh token → self-renews)
    # before trusting it, so a wrong/truncated note fails here, not at runtime.
    if printf '%s' "$codex_notes" | jq -e '.tokens.refresh_token' >/dev/null 2>&1; then
      printf '%s\n' "$codex_notes" > "$CODEX_AUTH"
      chmod 600 "$CODEX_AUTH"
      echo "    Codex auth.json seeded from Bitwarden item '$codex_item'."
    else
      echo "    WARN: '$codex_item' notes aren't valid Codex auth JSON — skipping seed." >&2
    fi
  else
    echo "    (No '$codex_item' notes in vault — run 'codex login --device-auth' to authenticate.)"
  fi
fi
# Lock the vault back up only if we unlocked it — a caller-provided
# BW_SESSION means they manage its lifecycle. Done here (not right after the
# key fetch) so the CLAUDE_CODE_OAUTH_TOKEN fetch and the Codex seed above can
# reuse the same unlock — locking earlier would invalidate the session.
if [ "${bw_unlocked_by_us:-false}" = true ]; then
  bw lock >/dev/null 2>&1 || true
fi

echo "==> Updating agent CLIs to latest (non-fatal — offline/rate-limit safe)"
# No sudo: --security-opt no-new-privileges disables it at runtime, and the
# Dockerfile-baked /usr/bin/{claude,codex} live in root-owned /usr, which npm
# can't rewrite even if the files themselves were chowned (rename needs write
# on the containing dir). Install into a vscode-owned prefix instead and put
# it first on PATH — shadows the baked-in fallback rather than replacing it.
mkdir -p "$HOME/.npm-global"
npm config set prefix "$HOME/.npm-global" >/dev/null 2>&1 || true
export PATH="$HOME/.npm-global/bin:$PATH"
if ! grep -q "# --- agent-devcontainer npm-global PATH ---" "$BASHRC"; then
  cat >> "$BASHRC" <<'EOF'

# --- agent-devcontainer npm-global PATH ---
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

echo "==> Self-authored skills (dotagents)"
# Self-authored skills (github-issue, etc.) live in Sadotu/agent-skills and are
# distributed via dotagents instead of a per-repo file copy — one command
# symlinks each skill into every tool's expected location (.claude/skills/,
# Codex's .agents/skills/, ...). The manifest is baked into the image; drop a
# copy into the workspace (without clobbering a project-customized one) since
# dotagents reads agents.toml from its working directory, not from a flag.
cp -n "$TOOLDIR/agents.toml" "$WORKSPACE/agents.toml" 2>/dev/null || true
(cd "$WORKSPACE" && npx -y @sentry/dotagents install 2>&1 | sed 's/^/    /') || \
  echo "WARNING: dotagents install failed — self-authored skills unavailable this run."

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
# A missing key would have aborted the script above (bw_fail) — reaching
# this line means the credentials are in the volume. Keep the check anyway
# as a cheap invariant guard.
if [ -r "$GITHUB_APP_DIR/private-key.pem" ] && [ -r "$GITHUB_APP_DIR/app-id" ]; then
  echo "2. GitHub App credentials: present."
else
  echo "2. GitHub App credentials: MISSING despite setup completing — this is a"
  echo "   bug; re-run ./.devcontainer/dc setup and watch the Bitwarden step."
fi
if [ -r "${CODEX_AUTH:-$HOME/.codex/auth.json}" ]; then
  echo "3. Codex CLI auth: present (seeded from Bitwarden or a prior login)."
else
  echo "3. Codex CLI auth: not seeded. Either put a working ~/.codex/auth.json in"
  echo "   the Notes of a Bitwarden item named 'codex-auth-token' for automatic"
  echo "   setup, or run 'codex login --device-auth' once — its browser OAuth"
  echo "   callback can't reach this container, so the device flow (code + URL"
  echo "   approved in any browser) is the manual path. Either keeps your ChatGPT"
  echo "   subscription billing and persists in the ~/.codex volume across rebuilds."
fi
echo "4. Do NOT run 'gh auth login' or 'gh auth setup-git' — this container"
echo "   uses the GitHub App exclusively (see 'GitHub App auth' in CLAUDE.md"
echo "   / AGENTS.md). 'gh'/'git push' work automatically once step 2 is done."
