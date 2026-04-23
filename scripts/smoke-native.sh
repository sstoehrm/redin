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
mkdir -p "$PROJECT/.redin" "$PROJECT/native"

echo "=== 1/5 extracting release tarball into .redin/ ==="
tar xzf "$TARBALL" -C "$PROJECT/.redin" --strip-components=1

# --- Simulate redin-cli upgrade-to-native --------------------------------
# The real CLI fetches src/host/ from a published source tarball. Pre-
# publish we use the current checkout instead — that's actually stronger,
# since it tests exactly the commit being released.
echo "=== 2/5 replaying upgrade-to-native (src/host, lib, vendor/luajit) ==="
cp -r "$REPO_ROOT/src/host/." "$PROJECT/native/"
cp -r "$PROJECT/.redin/lib"    "$PROJECT/native/lib"
mkdir -p "$PROJECT/native/vendor/luajit"
cp -r "$PROJECT/.redin/vendor/luajit/lib" "$PROJECT/native/vendor/luajit/"

# build.sh template — keep in sync with redin-cli's (redin-cli:build-sh).
cat > "$PROJECT/native/build.sh" <<'BUILD_SH'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
mkdir -p "$PROJECT_DIR/build"
odin build "$SCRIPT_DIR" \
  -collection:lib="$SCRIPT_DIR/lib" \
  -collection:luajit="$SCRIPT_DIR/vendor/luajit" \
  -out:"$PROJECT_DIR/build/redin"
BUILD_SH
chmod +x "$PROJECT/native/build.sh"

echo "=== 3/5 ./native/build.sh ==="
(cd "$PROJECT/native" && ./build.sh)

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
