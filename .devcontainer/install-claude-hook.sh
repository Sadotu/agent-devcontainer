#!/usr/bin/env bash
# Register Issue Orchestrator's fail-closed sub-agent gate in Claude's
# persisted user settings. Safe to re-run; existing settings/hooks survive.
set -euo pipefail

orchestrator_bin="$(readlink -f "$(command -v issue-orchestrator)")"
package_root="$(dirname "$(dirname "$orchestrator_bin")")"
hook_path="$package_root/hooks/pretooluse-usage-gate.mjs"
settings_dir="$HOME/.claude"
settings_path="$settings_dir/settings.json"

if [ ! -f "$hook_path" ]; then
  echo "ERROR: Issue Orchestrator Sentinel hook missing at $hook_path" >&2
  exit 1
fi

mkdir -p "$settings_dir"
settings_tmp="$(mktemp "$settings_dir/settings.json.XXXXXX")"
trap 'rm -f "$settings_tmp"' EXIT

node - "$settings_path" "$hook_path" >"$settings_tmp" <<'EOF'
const fs = require("fs");
const [settingsPath, hookPath] = process.argv.slice(2);
const settings = fs.existsSync(settingsPath)
  ? JSON.parse(fs.readFileSync(settingsPath, "utf8"))
  : {};

settings.hooks ??= {};
const existing = Array.isArray(settings.hooks.PreToolUse)
  ? settings.hooks.PreToolUse
  : [];
const staleProjectCommand = 'node "$CLAUDE_PROJECT_DIR/hooks/pretooluse-usage-gate.mjs"';
const installedCommand = `node "${hookPath}"`;
settings.hooks.PreToolUse = existing.flatMap((entry) => {
  if (entry?.matcher !== "Agent" || !Array.isArray(entry.hooks)) return [entry];
  const hooks = entry.hooks.filter(
    (hook) => ![staleProjectCommand, installedCommand].includes(hook?.command),
  );
  return hooks.length ? [{ ...entry, hooks }] : [];
});
settings.hooks.PreToolUse.push({
  matcher: "Agent",
  hooks: [{ type: "command", command: installedCommand }],
});

process.stdout.write(`${JSON.stringify(settings, null, 2)}\n`);
EOF

mv "$settings_tmp" "$settings_path"
trap - EXIT
echo "    Claude sub-agent Sentinel gate: $hook_path"
