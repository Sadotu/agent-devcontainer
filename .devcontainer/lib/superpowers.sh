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
