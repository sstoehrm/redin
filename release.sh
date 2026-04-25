#!/usr/bin/env bash
set -e

VERSION="${1:?Usage: ./release.sh <version> (e.g. v0.3.0)}"
PLATFORM="linux-amd64"
NAME="redin-${VERSION}-${PLATFORM}"
DIST="dist/${NAME}"

echo "Building redin ${VERSION}..."
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
echo "  Binary built: build/redin"

echo "Packaging ${NAME}.tar.gz..."
rm -rf dist
mkdir -p "${DIST}/docs/guide" "${DIST}/docs/reference" "${DIST}/runtime" "${DIST}/vendor" "${DIST}/lib" "${DIST}/.claude/skills/redin-dev"

# Binary
cp build/redin "${DIST}/redin"

# Runtime — AOT-compile Fennel to Lua 5.1 (matches release.yml).
for f in src/runtime/*.fnl; do
  name="$(basename "$f" .fnl)"
  luajit vendor/fennel/fennel.lua --compile "$f" > "${DIST}/runtime/${name}.lua"
done

# Vendor (fennel + luajit)
cp -r vendor/fennel "${DIST}/vendor/fennel"
cp -r vendor/luajit "${DIST}/vendor/luajit"

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

# Skill
cp .claude/skills/redin-dev/SKILL.md "${DIST}/.claude/skills/redin-dev/"

# Create tarball
cd dist
tar czf "${NAME}.tar.gz" "${NAME}"
cd ..

echo "  Created: dist/${NAME}.tar.gz"
echo ""
echo "Contents:"
tar tzf "dist/${NAME}.tar.gz" | head -30
echo "  ..."
echo ""
echo "Upload to GitHub:"
echo "  gh release create ${VERSION} dist/${NAME}.tar.gz --title ${VERSION}"
