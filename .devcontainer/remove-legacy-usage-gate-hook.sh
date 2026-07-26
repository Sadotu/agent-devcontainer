#!/usr/bin/env bash
# Idempotent cleanup for the retired Issue Orchestrator Claude PreToolUse
# usage-gate hook (see install-claude-hook.sh history / issue #28). Usage
# enforcement now lives in Sentinel; a normal Claude session must not be
# blocked by orchestrator-worker-only hook logic.
#
# Strips only the two known legacy hook commands from an existing
# ~/.claude/settings.json, leaving every other hook/setting untouched. If
# settings.json (or ~/.claude itself) doesn't exist, this is a no-op.
set -euo pipefail

settings_dir="$HOME/.claude"
settings_path="$settings_dir/settings.json"

[ -f "$settings_path" ] || exit 0

settings_tmp="$(mktemp "$settings_dir/settings.json.XXXXXX")"
trap 'rm -f "$settings_tmp"' EXIT

node - "$settings_path" >"$settings_tmp" <<'EOF'
const fs = require("fs");
const [settingsPath] = process.argv.slice(2);
const settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));

const legacyCommands = new Set([
  'node "$CLAUDE_PROJECT_DIR/hooks/pretooluse-usage-gate.mjs"',
  'node "/usr/lib/node_modules/issue-orchestrator/hooks/pretooluse-usage-gate.mjs"',
]);

const entries = Array.isArray(settings.hooks?.PreToolUse) ? settings.hooks.PreToolUse : [];
settings.hooks ??= {};
settings.hooks.PreToolUse = entries.flatMap((entry) => {
  if (entry?.matcher !== "Agent" || !Array.isArray(entry.hooks)) return [entry];
  const hooks = entry.hooks.filter((hook) => !legacyCommands.has(hook?.command));
  return hooks.length ? [{ ...entry, hooks }] : [];
});

process.stdout.write(`${JSON.stringify(settings, null, 2)}\n`);
EOF

mv "$settings_tmp" "$settings_path"
trap - EXIT
