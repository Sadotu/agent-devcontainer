#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REMOVER="$ROOT/.devcontainer/remove-legacy-usage-gate-hook.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f $REMOVER ]] || fail "remover script missing"

# --- Case 1: settings.json with both legacy commands + unrelated hooks ---
HOME="$TMP/home1"
mkdir -p "$HOME/.claude"
cat >"$HOME/.claude/settings.json" <<'EOF'
{
  "permissions": { "allow": ["Read"] },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "existing-hook" }]
      },
      {
        "matcher": "Agent",
        "hooks": [{ "type": "command", "command": "node \"$CLAUDE_PROJECT_DIR/hooks/pretooluse-usage-gate.mjs\"" }]
      },
      {
        "matcher": "Agent",
        "hooks": [{ "type": "command", "command": "node \"/usr/lib/node_modules/issue-orchestrator/hooks/pretooluse-usage-gate.mjs\"" }]
      },
      {
        "matcher": "Agent",
        "hooks": [{ "type": "command", "command": "node \"/custom/pretooluse-usage-gate.mjs\" --audit" }]
      }
    ]
  }
}
EOF

HOME="$HOME" bash "$REMOVER"

node - "$HOME/.claude/settings.json" <<'EOF' || fail "case 1: settings not cleaned correctly"
const fs = require("fs");
const settings = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (settings.permissions?.allow?.[0] !== "Read") throw new Error("unrelated settings key lost");
const entries = settings.hooks?.PreToolUse ?? [];
if (!entries.some((e) => e.matcher === "Bash" && e.hooks?.[0]?.command === "existing-hook")) {
  throw new Error("unrelated Bash hook lost");
}
if (!entries.some((e) => e.matcher === "Agent" && e.hooks?.[0]?.command === 'node "/custom/pretooluse-usage-gate.mjs" --audit')) {
  throw new Error("unrelated same-basename Agent hook lost");
}
const legacyStale = 'node "$CLAUDE_PROJECT_DIR/hooks/pretooluse-usage-gate.mjs"';
const legacyAbsolute = 'node "/usr/lib/node_modules/issue-orchestrator/hooks/pretooluse-usage-gate.mjs"';
const commands = entries.filter((e) => e.matcher === "Agent").flatMap((e) => e.hooks ?? []).map((h) => h.command);
if (commands.includes(legacyStale)) throw new Error("stale legacy command still present");
if (commands.includes(legacyAbsolute)) throw new Error("absolute legacy command still present");
if (entries.length !== 2) throw new Error(`expected 2 surviving PreToolUse entries, got ${entries.length}`);
EOF

# --- Case 2: idempotent rerun ---
settings_after_first="$(cat "$HOME/.claude/settings.json")"
HOME="$HOME" bash "$REMOVER"
[[ "$(cat "$HOME/.claude/settings.json")" == "$settings_after_first" ]] || fail "rerun changed settings"

# --- Case 3: no settings.json present is a clean no-op ---
HOME="$TMP/home2"
mkdir -p "$HOME/.claude"
HOME="$HOME" bash "$REMOVER"
[[ ! -f "$HOME/.claude/settings.json" ]] || fail "no-op case created a settings.json"

# --- Case 4: no ~/.claude dir at all ---
HOME="$TMP/home3"
mkdir -p "$HOME"
HOME="$HOME" bash "$REMOVER"
[[ ! -e "$HOME/.claude" ]] || fail "no-op case created ~/.claude"

# --- Case 5: settings.json with no hooks key (valid settings structure) ---
HOME="$TMP/home4"
mkdir -p "$HOME/.claude"
cat >"$HOME/.claude/settings.json" <<'EOF'
{"permissions": {"allow": ["Read"]}}
EOF

HOME="$HOME" bash "$REMOVER"

node - "$HOME/.claude/settings.json" <<'EOF' || fail "case 5: settings.json with no hooks key not handled correctly"
const fs = require("fs");
const settings = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (settings.permissions?.allow?.[0] !== "Read") throw new Error("permissions.allow[0] not preserved");
EOF

echo "PASS: legacy Claude usage-gate hook removal"
