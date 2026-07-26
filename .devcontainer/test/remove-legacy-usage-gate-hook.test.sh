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

# --- Case 6: legacy command under a non-"Agent" matcher is still removed ---
HOME="$TMP/home5"
mkdir -p "$HOME/.claude"
cat >"$HOME/.claude/settings.json" <<'EOF'
{
  "permissions": { "allow": ["Read"] },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "node \"$CLAUDE_PROJECT_DIR/hooks/pretooluse-usage-gate.mjs\"" }]
      },
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "node \"/usr/lib/node_modules/issue-orchestrator/hooks/pretooluse-usage-gate.mjs\"" }]
      },
      {
        "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "existing-hook" }]
      }
    ]
  }
}
EOF

HOME="$HOME" bash "$REMOVER"

node - "$HOME/.claude/settings.json" <<'EOF' || fail "case 6: legacy command under non-Agent matcher not removed"
const fs = require("fs");
const settings = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (settings.permissions?.allow?.[0] !== "Read") throw new Error("unrelated settings key lost");
const entries = settings.hooks?.PreToolUse ?? [];
const commands = entries.flatMap((e) => e.hooks ?? []).map((h) => h.command);
if (commands.includes('node "$CLAUDE_PROJECT_DIR/hooks/pretooluse-usage-gate.mjs"')) {
  throw new Error("stale legacy command (matcher: Bash) still present");
}
if (commands.includes('node "/usr/lib/node_modules/issue-orchestrator/hooks/pretooluse-usage-gate.mjs"')) {
  throw new Error("absolute legacy command (matcher: \"\") still present");
}
if (!commands.includes("existing-hook")) throw new Error("unrelated Bash hook lost");
if (entries.length !== 1) throw new Error(`expected 1 surviving PreToolUse entry, got ${entries.length}`);
EOF

# --- Case 7: no legacy commands present leaves the file byte-for-byte untouched ---
# Written pre-formatted to match Node's JSON.stringify(obj, null, 2) output
# exactly (2-space indent, one array element per line) so a real "nothing to
# do" run can be verified byte-for-byte rather than just semantically equal.
HOME="$TMP/home6"
mkdir -p "$HOME/.claude"
cat >"$HOME/.claude/settings.json" <<'EOF'
{
  "permissions": {
    "allow": [
      "Read"
    ]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "existing-hook"
          }
        ]
      }
    ]
  }
}
EOF

sha_before="$(sha256sum "$HOME/.claude/settings.json" | awk '{print $1}')"
HOME="$HOME" bash "$REMOVER"
sha_after="$(sha256sum "$HOME/.claude/settings.json" | awk '{print $1}')"
[[ "$sha_before" == "$sha_after" ]] || fail "case 7: settings.json rewritten even though nothing changed"

echo "PASS: legacy Claude usage-gate hook removal"
