#!/usr/bin/env bash
# Superpowers plugin install/update for both agent CLIs, sourced by
# setup-agents.sh (postCreate). Sourceable library — defines functions only,
# no top-level side effects, no `set -e` of its own (the sourcing script owns
# shell options), same contract as lib/bw-session.sh and lib/setup-marker.sh.
#
# Issue #60: setup used to *install* Superpowers but never *update* it.
# `claude plugin marketplace add` / `claude plugin install` both no-op once
# the marketplace/plugin exist, and Codex's local marketplace was cloned only
# when its directory was missing — on a persisted ~/.codex that clone never
# ran again. Both agents drifted (observed: Claude 6.1.1, Codex 5.1.3,
# upstream 6.3.0).
#
# Plugin freshness must never fail the container: every CLI call is
# non-fatal and every function returns 0.

CODEX_SP_DIR="${CODEX_SP_DIR:-$HOME/.codex/marketplaces/superpowers-curated}"

# Claude: `add`/`install` handle the first run and no-op afterwards;
# `marketplace update`/`plugin update` are the only verbs that advance an
# existing installation. `marketplace update` fails outright when the
# marketplace was never added, so `add` has to stay and run first.
superpowers_update_claude() {
  claude plugin marketplace add obra/superpowers-marketplace 2>&1 | sed 's/^/    /' || true
  claude plugin install superpowers@superpowers-marketplace 2>&1 | sed 's/^/    /' || true
  claude plugin marketplace update superpowers-marketplace 2>&1 | sed 's/^/    /' || true
  claude plugin update superpowers@superpowers-marketplace 2>&1 | sed 's/^/    /' || true
  return 0
}

# Codex reserves the marketplace name "openai-curated" (what openai/plugins'
# own manifest declares) and refuses it headlessly, so the plugin is copied
# into a local marketplace dir under a different name. `codex plugin
# marketplace upgrade` only refreshes *Git* marketplace snapshots, so it can
# never touch a local one — the only way to advance Codex is to refresh this
# directory's contents and re-run `codex plugin add`, which re-resolves the
# version from the manifest and replaces its versioned cache.
#
# The clone runs on every setup, not just when the directory is missing
# (issue #60): ~/.codex is a persisted volume, so the old
# `[ ! -d "$CODEX_SP_DIR" ]` guard pinned Codex forever. New content is
# staged beside the live tree and swapped in, so a partial copy can never
# replace a working install, and files deleted upstream do not linger.
superpowers_update_codex() {
  local tmp_clone staged live
  tmp_clone="$(mktemp -d)"
  if ! git clone --depth 1 https://github.com/openai/plugins "$tmp_clone" \
      >/tmp/codex-superpowers-clone.log 2>&1; then
    echo "WARNING: failed to clone openai/plugins for Codex superpowers."
    echo "         See /tmp/codex-superpowers-clone.log for details."
    echo "         Keeping the existing Codex Superpowers copy, if any."
    rm -rf "$tmp_clone"
    return 0
  fi

  live="$CODEX_SP_DIR/plugins/superpowers"
  staged="$CODEX_SP_DIR/plugins/.superpowers.new"
  mkdir -p "$CODEX_SP_DIR/plugins" "$CODEX_SP_DIR/.agents/plugins"
  rm -rf "$staged"
  mkdir -p "$staged"
  cp -r "$tmp_clone/plugins/superpowers/." "$staged/"
  rm -rf "$tmp_clone"
  rm -rf "$live"
  mv "$staged" "$live"

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

  codex plugin marketplace add "$CODEX_SP_DIR" 2>&1 | sed 's/^/    /' || true
  codex plugin add superpowers@superpowers-curated 2>&1 | sed 's/^/    /' || true
  return 0
}

# Print the installed Superpowers version for each agent so drift is visible
# in the setup log instead of silent. `plugin list --json` is an explicit
# read-only subcommand on both CLIs — deliberately NOT a bare or flag-based
# invocation, which this repo has twice mistaken for a version probe
# (issue-orchestrator, worktree-warden) and started a daemon instead. The two
# CLIs disagree on shape: Claude returns a flat array of {id, version}, Codex
# wraps its entries in `.installed` and keys them `pluginId`.
# Reporting is never fatal: anything unreadable degrades to `unknown`. The
# `|| true` belongs on the whole pipeline, not just the assignment — under the
# caller's `set -euo pipefail` a failing `plugin list` makes the pipeline
# nonzero even though `jq` succeeded, and that would abort setup outright.
superpowers_report_versions() {
  local claude_version codex_version
  claude_version="$(claude plugin list --json 2>/dev/null \
    | jq -r 'map(select(.id | startswith("superpowers@"))) | .[0].version // empty' 2>/dev/null || true)"
  codex_version="$(codex plugin list --json 2>/dev/null \
    | jq -r '.installed | map(select(.pluginId | startswith("superpowers@"))) | .[0].version // empty' 2>/dev/null || true)"
  printf '    Superpowers (Claude): %s\n' "${claude_version:-unknown}"
  printf '    Superpowers (Codex):  %s\n' "${codex_version:-unknown}"
  return 0
}
