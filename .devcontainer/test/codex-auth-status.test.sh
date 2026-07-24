#!/usr/bin/env bash
# Tests the Codex-auth status reporting in setup-agents.sh (issue #13):
# the already-present case must print an explicit line during the run, the
# seed path must be unchanged, and the final checklist gains a `->` callout.
#
# setup-agents.sh is a monolithic script that can't be sourced without running
# its whole (network-touching) body, so we extract just the two relevant blocks
# by their stable boundaries and run each in a fake $HOME with stubbed
# ensure_bw_session/bw. Real jq is used (present in the image).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/.devcontainer/setup-agents.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -r "$SCRIPT" ] || fail "setup-agents.sh not found at $SCRIPT"

# Extract the Codex-auth seed block: from `CODEX_AUTH="..."` up to (not
# including) the "Lock the vault back up" comment that follows it.
seed_block() {
  awk '/^CODEX_AUTH="\$HOME\/\.codex\/auth\.json"$/{f=1}
       /^# Lock the vault back up/{f=0}
       f' "$SCRIPT"
}

# Extract the final-checklist item 3 block: the `if [ -r "${CODEX_AUTH...` up to
# (not including) checklist item 4.
checklist_block() {
  awk '/^if \[ -r "\$\{CODEX_AUTH:/{f=1}
       /^echo "4\. Do NOT run/{f=0}
       f' "$SCRIPT"
}

[ -n "$(seed_block)" ]      || fail "could not extract Codex seed block"
[ -n "$(checklist_block)" ] || fail "could not extract checklist item-3 block"

# Common stub preamble: fake vault helpers, dummy session, safe defaults.
# ensure_bw_session records that it was called (tripwire) and returns $BW_RC.
# bw prints $NOTES for `get notes`.
stub_preamble() {
  cat <<'STUB'
set -euo pipefail
: "${BW_RC:=0}"
: "${NOTES:=}"
: "${codex_auth_status:=unseeded}"
BW_SESSION=dummy
ensure_bw_session() { echo called >>"$TRIP"; return "$BW_RC"; }
bw() { case "$*" in get\ notes*) printf '%s' "$NOTES";; *) : ;; esac; }
STUB
}

run_seed() {  # runs the seed block; stdout captured by caller
  { stub_preamble; seed_block; } | bash
}
run_checklist() {
  { stub_preamble; checklist_block; } | bash
}

# --- Case 1: auth.json already present -> explicit line, no vault unlock ------
HOME="$TMP/present"; export HOME
mkdir -p "$HOME/.codex"; echo '{}' > "$HOME/.codex/auth.json"
TRIP="$TMP/trip1"; export TRIP; : > "$TRIP"
out="$(HOME="$HOME" TRIP="$TRIP" run_seed)"
echo "$out" | grep -qi 'already present' \
  || fail "present case: expected an 'already present' line, got: $out"
[ ! -s "$TRIP" ] \
  || fail "present case: ensure_bw_session was called but must not be"

# --- Case 2: auth.json absent + valid notes -> seeds as before ----------------
HOME="$TMP/absent-ok"; export HOME
mkdir -p "$HOME"
TRIP="$TMP/trip2"; : > "$TRIP"
NOTES='{"tokens":{"refresh_token":"rt","access_token":"at"}}'
out="$(HOME="$HOME" TRIP="$TRIP" BW_RC=0 NOTES="$NOTES" run_seed)"
echo "$out" | grep -qi 'seeded from Bitwarden' \
  || fail "absent+valid case: expected a 'seeded' line, got: $out"
[ -r "$HOME/.codex/auth.json" ] \
  || fail "absent+valid case: auth.json was not written"

# --- Case 3: auth.json absent + vault unlock fails -> silent ------------------
HOME="$TMP/absent-fail"; export HOME
mkdir -p "$HOME"
TRIP="$TMP/trip3"; : > "$TRIP"
out="$(HOME="$HOME" TRIP="$TRIP" BW_RC=1 run_seed)"
[ -z "$out" ] \
  || fail "absent+unlock-fail case: expected no output, got: $out"

# --- Case 4: checklist callout distinguishes present vs freshly-seeded --------
HOME="$TMP/present"; export HOME   # reuse the dir with auth.json
out="$(HOME="$HOME" codex_auth_status=already-present run_checklist)"
echo "$out" | grep -qi 'already present, no fetch' \
  || fail "checklist: already-present callout missing, got: $out"
out="$(HOME="$HOME" codex_auth_status=freshly-seeded run_checklist)"
echo "$out" | grep -qi 'freshly seeded' \
  || fail "checklist: freshly-seeded callout missing, got: $out"

echo "PASS: codex-auth-status.test.sh (4 cases)"
