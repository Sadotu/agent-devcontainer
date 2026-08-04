#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$ROOT/.devcontainer/test-all.sh"
README="$ROOT/README.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -x $RUNNER ]] || fail "runner missing or not executable: $RUNNER"

# --- fixture: two passing suites + an image-smoke that asserts the arg it got ---
# image-smoke.sh in the fixture exits nonzero unless it received exactly the
# argument the runner is expected to pass, so a green run *proves* the invocation.
mkdir -p "$TMP/ok"
cat >"$TMP/ok/a.test.sh" <<'EOF'
#!/usr/bin/env bash
echo "a ran"
EOF
cat >"$TMP/ok/b.test.sh" <<'EOF'
#!/usr/bin/env bash
echo "b ran"
EOF
cat >"$TMP/ok/image-smoke.sh" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-<none>}" == "$EXPECT_ARG" ]] || { echo "got '${1:-<none>}' want '$EXPECT_ARG'" >&2; exit 9; }
EOF

# source mode: image-smoke.sh must be invoked with --source-only
out="$(EXPECT_ARG=--source-only TEST_ALL_DIR="$TMP/ok" bash "$RUNNER")"; rc=$?
[[ $rc -eq 0 ]] || fail "source-mode run failed (exit $rc): $out"
grep -q 'a.test.sh' <<<"$out" || fail "source-mode: a.test.sh not reported"
grep -q 'b.test.sh' <<<"$out" || fail "source-mode: b.test.sh not reported"
grep -q 'image-smoke.sh' <<<"$out" || fail "source-mode: image-smoke.sh not reported"

# image mode: an image tag passes through to image-smoke.sh only
out="$(EXPECT_ARG=myimage:tag TEST_ALL_DIR="$TMP/ok" bash "$RUNNER" myimage:tag)"; rc=$?
[[ $rc -eq 0 ]] || fail "image-mode run failed (exit $rc): $out"

# --- fixture: a failing suite alongside a passing one ---
mkdir -p "$TMP/bad"
cat >"$TMP/bad/pass.test.sh" <<'EOF'
#!/usr/bin/env bash
echo ok
EOF
cat >"$TMP/bad/image-smoke.sh" <<'EOF'
#!/usr/bin/env bash
:
EOF
cat >"$TMP/bad/boom.test.sh" <<'EOF'
#!/usr/bin/env bash
for i in $(seq 1 50); do printf 'L%02d\n' "$i"; done
exit 1
EOF

set +e
out="$(EXPECT_ARG=--source-only TEST_ALL_DIR="$TMP/bad" bash "$RUNNER" 2>&1)"; rc=$?
set -e
[[ $rc -ne 0 ]] || fail "failing suite did not make the runner exit nonzero"
grep -Eq 'FAIL[[:space:]]+boom.test.sh' <<<"$out" || fail "no FAIL line for boom.test.sh: $out"
grep -Eq '(PASS|ok)[[:space:]]+pass.test.sh|pass.test.sh' <<<"$out" || fail "passing suite not still run"

# bounded failure context: last 30 lines only (L21..L50), earlier lines dropped
grep -q 'L50' <<<"$out" || fail "failure tail missing last line L50"
grep -q 'L21' <<<"$out" || fail "failure tail missing L21 (should be within 30-line tail)"
grep -q 'L20' <<<"$out" && fail "failure tail not bounded — L20 present (older than 30 lines)"
grep -q 'L01' <<<"$out" && fail "failure tail not bounded — L01 present"

# --- extensibility: a brand-new *.sh suite is picked up with no runner edit ---
cat >"$TMP/ok/c.test.sh" <<'EOF'
#!/usr/bin/env bash
echo "c ran"
EOF
out="$(EXPECT_ARG=--source-only TEST_ALL_DIR="$TMP/ok" bash "$RUNNER")"
grep -q 'c.test.sh' <<<"$out" || fail "newly added suite not auto-discovered"

# --- documentation ---
grep -q 'test-all.sh' "$README" || fail "README does not document test-all.sh"

echo "PASS: test-all.test.sh"
