#!/usr/bin/env bash
# Bumps the vendored Sadotu/issue-orchestrator package baked into the image.
#
# Usage: .devcontainer/bump-vendor.sh /path/to/issue-orchestrator-checkout
#
# Packs the source checkout's HEAD commit (tracked files only, via
# `git archive` — NOT the raw working tree, which may hold untracked local
# scratch files or stray `git worktree add` checkouts that `npm pack` would
# otherwise sweep in), drops the tarball in .devcontainer/vendor/, deletes
# the old one, and rewrites the Dockerfile's COPY/RUN lines and commit/SHA-256
# comment to match. Run `.devcontainer/test/image-smoke.sh --source-only`
# afterwards to confirm the Dockerfile and tarball agree.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "Usage: $0 /path/to/issue-orchestrator-checkout" >&2; exit 2; }
SRC="$1"
[[ -d "$SRC/.git" ]] || { echo "ERROR: $SRC is not a git checkout" >&2; exit 1; }

DEVCONTAINER_DIR="$(cd "$(dirname "$0")" && pwd)"
VENDOR_DIR="$DEVCONTAINER_DIR/vendor"
DOCKERFILE="$DEVCONTAINER_DIR/Dockerfile"

full_commit="$(git -C "$SRC" rev-parse HEAD)"
short_commit="$(git -C "$SRC" rev-parse --short=12 HEAD)"
pkg_version="$(node -pe "require('$SRC/package.json').version")"

tmp_clean="$(mktemp -d)"
tmp_pack="$(mktemp -d)"
trap 'rm -rf "$tmp_clean" "$tmp_pack"' EXIT

git -C "$SRC" archive HEAD | tar -x -C "$tmp_clean"
(cd "$tmp_clean" && npm pack --silent --pack-destination "$tmp_pack" >/dev/null)

packed="$(find "$tmp_pack" -maxdepth 1 -name '*.tgz')"
[[ -n "$packed" ]] || { echo "ERROR: npm pack produced no tarball" >&2; exit 1; }

sha256="$(sha256sum "$packed" | cut -d' ' -f1)"
new_name="issue-orchestrator-${short_commit}.tgz"

rm -f "$VENDOR_DIR"/issue-orchestrator-*.tgz
cp "$packed" "$VENDOR_DIR/$new_name"

sed -i \
  -e "s|^# commit [0-9a-f]\+ (package version .*)\.\$|# commit ${full_commit} (package version ${pkg_version}).|" \
  -e "s|^# SHA-256 [0-9a-f]\+\.\$|# SHA-256 ${sha256}.|" \
  -e "s|vendor/issue-orchestrator-[0-9a-f]\+\.tgz|vendor/${new_name}|g" \
  "$DOCKERFILE"

echo "Vendored issue-orchestrator @ ${short_commit} (v${pkg_version}) -> ${new_name}"
echo "SHA-256 ${sha256}"
