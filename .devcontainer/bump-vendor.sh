#!/usr/bin/env bash
# Bumps a vendored Sadotu/<package> package baked into the image.
#
# Usage: .devcontainer/bump-vendor.sh /path/to/<package>-checkout <package-name>
#
# Packs the source checkout's HEAD commit (tracked files only, via
# `git archive` — NOT the raw working tree, which may hold untracked local
# scratch files or stray `git worktree add` checkouts that `npm pack` would
# otherwise sweep in), drops the tarball in .devcontainer/vendor/, deletes
# the old one for that package, and rewrites that package's block in the
# Dockerfile's COPY/RUN lines and commit/SHA-256 comment to match. Run
# `.devcontainer/test/image-smoke.sh --source-only` afterwards to confirm
# the Dockerfile and tarball agree.
set -euo pipefail

[[ $# -eq 2 ]] || { echo "Usage: $0 /path/to/<package>-checkout <package-name>" >&2; exit 2; }
SRC="$1"
PKG="$2"
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
new_name="${PKG}-${short_commit}.tgz"

rm -f "$VENDOR_DIR/${PKG}"-*.tgz
cp "$packed" "$VENDOR_DIR/$new_name"

# Only touch the block belonging to this package: the commit/SHA-256 comment
# lines are shared formatting across every vendored package's block, so we
# scope each sed to a line range anchored on that package's own
# `vendor/<pkg>-<hex>.tgz` reference already present in the Dockerfile (the
# COPY line for a first-time addition must exist before this script can find
# anything to rewrite — see bump-vendor usage notes).
anchor_line="$(grep -n "vendor/${PKG}-[0-9a-f]\+\.tgz" "$DOCKERFILE" | head -1 | cut -d: -f1)"
[[ -n "$anchor_line" ]] || {
    echo "ERROR: no existing vendor/${PKG}-<commit>.tgz reference found in $DOCKERFILE" >&2
    echo "Add the package's Dockerfile block (COPY + npm install line) first, then re-run." >&2
    exit 1
}

# Walk backwards from the anchor to find this block's own commit/SHA-256
# comment lines (within the preceding few lines of the COPY statement).
block_start=$(( anchor_line > 10 ? anchor_line - 10 : 1 ))

sed -i \
  -e "${block_start},${anchor_line}s|^# commit [0-9a-f]\+ (package version .*)\.\$|# commit ${full_commit} (package version ${pkg_version}).|" \
  -e "${block_start},${anchor_line}s|^# SHA-256 [0-9a-f]\+\.\$|# SHA-256 ${sha256}.|" \
  -e "s|vendor/${PKG}-[0-9a-f]\+\.tgz|vendor/${new_name}|g" \
  "$DOCKERFILE"

echo "Vendored ${PKG} @ ${short_commit} (v${pkg_version}) -> ${new_name}"
echo "SHA-256 ${sha256}"
