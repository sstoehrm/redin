#!/usr/bin/env bash
set -e

VERSION="${1:?Usage: ./release.sh <version> (e.g. v0.3.0)}"
PLATFORM="linux-amd64"
NAME="redin-${VERSION}-${PLATFORM}"
DIST="dist/${NAME}"

echo "Building redin ${VERSION}..."
./build-dev.sh
echo "  Binary built: build/redin"

echo "Packaging ${NAME}.tar.gz..."
rm -rf dist
mkdir -p "${DIST}/docs/guide" "${DIST}/docs/reference" "${DIST}/runtime" "${DIST}/vendor" "${DIST}/lib" "${DIST}/skills/redin-dev"

# Binary
cp build/redin "${DIST}/redin"

# Runtime — AOT-compile Fennel to Lua 5.1 (matches release.yml).
for f in src/runtime/*.fnl; do
  name="$(basename "$f" .fnl)"
  luajit vendor/fennel/fennel.lua --compile "$f" > "${DIST}/runtime/${name}.lua"
done

# Vendor (fennel + luajit) — copy only the files the build needs, matching
# release.yml. #225 L9: `cp -r vendor/luajit` pulled in the whole local dir
# (BUILD.md, any local build artifacts, a stray .git), none of which should
# ship in a release tarball.
mkdir -p "${DIST}/vendor/fennel" "${DIST}/vendor/luajit/lib"
cp vendor/fennel/fennel.lua "${DIST}/vendor/fennel/"
cp vendor/luajit/lib/libluajit-5.1.a "${DIST}/vendor/luajit/lib/"

# Lib (odin-http submodule, for upgrade-to-native builds).
# Exclude Windows-only static libs and non-source dirs to keep the tarball small.
rsync -a \
  --exclude='openssl/includes' \
  --exclude='docs' \
  --exclude='examples' \
  --exclude='comparisons' \
  --exclude='old_nbio' \
  lib/odin-http/ "${DIST}/lib/odin-http/"

# Docs — API docs
cp docs/core-api.md "${DIST}/docs/"
cp docs/app-api.md "${DIST}/docs/"

# Docs — guides
cp docs/guide/*.md "${DIST}/docs/guide/"

# Docs — reference
cp docs/reference/*.md "${DIST}/docs/reference/"

# Skill — must live at skills/ in the bundle (matches release.yml):
# redin-cli extracts the tarball into .redin/ and mirrors .redin/skills/
# into the project's .claude/skills/. A .claude/ dir at bundle root would
# land at .redin/.claude/ and never be picked up.
cp .claude/skills/redin-dev/SKILL.md "${DIST}/skills/redin-dev/"

# Create tarball — FLAT, matching release.yml's `tar czf ... -C dist .`.
# redin-cli extracts with plain `tar xzf ... -C .redin` (no
# --strip-components), so a `${NAME}/` directory prefix breaks
# `redin-cli update` (v0.7.0 regression: .redin/redin went missing).
cd dist
tar czf "${NAME}.tar.gz" -C "${NAME}" .
# SHA-256 sidecar, matching release.yml (#136 L4 / #225 L9). Downstream
# tooling and manual `sha256sum -c` use it to detect a corrupt or swapped
# tarball. Written next to the tarball inside dist/.
sha256sum "${NAME}.tar.gz" > "${NAME}.tar.gz.sha256"
cd ..

echo "  Created: dist/${NAME}.tar.gz"
echo "  Created: dist/${NAME}.tar.gz.sha256"
echo ""
echo "Contents:"
tar tzf "dist/${NAME}.tar.gz" | head -30
echo "  ..."
echo ""
echo "Upload to GitHub:"
echo "  gh release create ${VERSION} dist/${NAME}.tar.gz dist/${NAME}.tar.gz.sha256 --title ${VERSION}"
