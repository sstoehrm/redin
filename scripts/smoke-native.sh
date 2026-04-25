#!/usr/bin/env bash
# smoke-native.sh — pre-publish smoke test of the release tarball.
#
# Takes the release tarball and simulates redin-cli's upgrade-to-native
# flow against the current checkout: extract tarball → native/ tree →
# ./build.sh → launch binary under --dev → curl /state.
#
# Catches contract breaks between the host source and the release tarball
# (missing files, bad collection paths, runtime asset lookup) before the
# tarball is published. redin-cli has its own CI that exercises the real
# CLI against the latest published release; this script exists to catch
# the same class of bugs one step earlier.
#
# Usage:
#   scripts/smoke-native.sh <path-to-release-tarball>
#
# Requires: odin, bash, tar, curl. xvfb-run optional (used if present).

set -euo pipefail

TARBALL="${1:?usage: scripts/smoke-native.sh <path-to-release-tarball>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -f "$TARBALL" ]; then
  echo "ERROR: tarball not found: $TARBALL" >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PROJECT="$WORK/app"
mkdir -p "$PROJECT/.redin"

echo "=== 1/5 extracting release tarball into .redin/ ==="
tar xzf "$TARBALL" -C "$PROJECT/.redin" --strip-components=1

# --- Simulate redin-cli new-fnl --native (RFC #79) -----------------------
# The CLI will fetch redin source from a published source tarball into
# .redin/src/redin/. Pre-publish we copy from the current checkout — that's
# actually stronger, since it tests exactly the commit being released.
echo "=== 2/5 staging .redin/src/redin/ + project app.odin + build.sh ==="
mkdir -p "$PROJECT/.redin/src/redin"
cp -r "$REPO_ROOT/src/redin/." "$PROJECT/.redin/src/redin/"

# Minimal user-owned app.odin. Mirrors what redin-cli new-fnl --native
# scaffolds (RFC #79 PR 3).
cat > "$PROJECT/app.odin" <<'APP_ODIN'
package main

import redin "./.redin/src/redin"

main :: proc() {
	cfg: redin.Config
	cfg.dev = true
	cfg.app = "main.fnl"
	redin.run(cfg)
}
APP_ODIN

# Project-root build.sh template — also mirrors PR 3's scaffold.
cat > "$PROJECT/build.sh" <<'BUILD_SH'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$SCRIPT_DIR/build"
odin build "$SCRIPT_DIR" \
  -collection:lib="$SCRIPT_DIR/.redin/lib" \
  -collection:luajit="$SCRIPT_DIR/.redin/vendor/luajit" \
  -out:"$SCRIPT_DIR/build/redin"
BUILD_SH
chmod +x "$PROJECT/build.sh"

echo "=== 3/5 ./build.sh (project root) ==="
(cd "$PROJECT" && ./build.sh)

cat > "$PROJECT/main.fnl" <<'FNL'
;; The smoke check asserts /frames contains this sentinel, which only
;; shows up if the Fennel runtime loaded AND main_view got called.
(global main_view (fn [] [:text {} "redin-smoke-ok"]))
FNL

LAUNCHER=()
if command -v xvfb-run >/dev/null 2>&1; then
  LAUNCHER=(xvfb-run -a -s "-screen 0 1280x800x24")
else
  echo "  note: xvfb-run not on PATH — launching against the host display"
fi

cd "$PROJECT"
rm -f .redin-port .redin-token

echo "=== 4/5 launching build/redin --dev ==="
"${LAUNCHER[@]}" "$PROJECT/build/redin" --dev main.fnl &
PID=$!

cleanup() {
  if [ -f .redin-port ] && [ -f .redin-token ]; then
    PORT="$(cat .redin-port)"; TOKEN="$(cat .redin-token)"
    curl -s -X POST -H "Authorization: Bearer $TOKEN" \
      "http://localhost:$PORT/shutdown" >/dev/null || true
  fi
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
}
trap 'cleanup; rm -rf "$WORK"' EXIT

echo "=== 5/5 polling /frames for sentinel ==="
# Strong check: the sentinel proves the Fennel runtime loaded and main_view
# ran. Just curling /state would return 200 even if the runtime failed to
# load (the dev server comes up independently).
TIMEOUT=30
for _ in $(seq 1 "$TIMEOUT"); do
  if [ -f .redin-port ] && [ -f .redin-token ]; then
    PORT="$(cat .redin-port)"; TOKEN="$(cat .redin-token)"
    body="$(curl -sf -H "Authorization: Bearer $TOKEN" \
                 "http://localhost:$PORT/frames" 2>/dev/null || true)"
    if [ -n "$body" ] && printf '%s' "$body" | grep -q 'redin-smoke-ok'; then
      echo "  /frames contains sentinel — smoke check PASSED"
      exit 0
    fi
  fi
  # If the process died early, bail.
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "ERROR: native binary exited before smoke check completed" >&2
    exit 1
  fi
  sleep 1
done

echo "ERROR: sentinel did not appear in /frames within ${TIMEOUT}s" >&2
echo "       (runtime probably failed to load — check binary stderr above)" >&2
exit 1
