#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$ROOT/.devcontainer/install-claude-hook.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

HOME="$TMP/home"
PACKAGE_ROOT="$TMP/npm/lib/node_modules/issue-orchestrator"
mkdir -p "$HOME/.claude" "$PACKAGE_ROOT/bin" "$PACKAGE_ROOT/hooks" "$TMP/bin"
touch "$PACKAGE_ROOT/bin/supervisor.mjs" "$PACKAGE_ROOT/hooks/pretooluse-usage-gate.mjs"
ln -s "$PACKAGE_ROOT/bin/supervisor.mjs" "$TMP/bin/issue-orchestrator"

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
        "hooks": [{ "type": "command", "command": "node \"/custom/pretooluse-usage-gate.mjs\" --audit" }]
      }
    ]
  }
}
EOF

[[ -f $INSTALLER ]] || fail "Claude hook installer missing"
HOME="$HOME" PATH="$TMP/bin:$PATH" bash "$INSTALLER"
HOME="$HOME" PATH="$TMP/bin:$PATH" bash "$INSTALLER"

node - "$HOME/.claude/settings.json" "$PACKAGE_ROOT/hooks/pretooluse-usage-gate.mjs" <<'EOF' || fail "Claude settings not merged correctly"
const fs = require("fs");
const [settingsPath, hookPath] = process.argv.slice(2);
const settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
if (settings.permissions?.allow?.[0] !== "Read") throw new Error("existing settings lost");
const entries = settings.hooks?.PreToolUse ?? [];
if (!entries.some((entry) => entry.matcher === "Bash" && entry.hooks?.[0]?.command === "existing-hook")) {
  throw new Error("unrelated hook lost");
}
if (!entries.some((entry) => entry.matcher === "Agent" && entry.hooks?.[0]?.command === 'node "/custom/pretooluse-usage-gate.mjs" --audit')) {
  throw new Error("unrelated same-basename Agent hook lost");
}
const gateCommands = entries
  .filter((entry) => entry.matcher === "Agent")
  .flatMap((entry) => entry.hooks ?? [])
  .map((hook) => hook.command)
  .filter((command) => command !== 'node "/custom/pretooluse-usage-gate.mjs" --audit' && command?.includes("pretooluse-usage-gate.mjs"));
const expected = `node "${hookPath}"`;
if (gateCommands.length !== 1 || gateCommands[0] !== expected) {
  throw new Error(`expected one absolute gate ${JSON.stringify(expected)}, got ${JSON.stringify(gateCommands)}`);
}
if (!hookPath.startsWith("/") || gateCommands[0].includes("CLAUDE_PROJECT_DIR")) {
  throw new Error("gate path is not absolute");
}
EOF

settings_before="$(sha256sum "$HOME/.claude/settings.json")"
rm "$PACKAGE_ROOT/hooks/pretooluse-usage-gate.mjs"
if HOME="$HOME" PATH="$TMP/bin:$PATH" bash "$INSTALLER" >/dev/null 2>&1; then
  fail "installer accepted missing packaged hook"
fi
[[ $(sha256sum "$HOME/.claude/settings.json") == "$settings_before" ]] ||
  fail "missing-hook failure mutated Claude settings"

echo "PASS: Claude user-level Sentinel hook"
