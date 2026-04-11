#!/usr/bin/env bash
# Run all UI integration tests.
# Each test_<name>.bb is paired with <name>_app.fnl.
# The script builds redin, then for each pair starts the dev server,
# waits for it to be ready, runs the test, and shuts it down.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BINARY="$ROOT_DIR/build/redin"
PORT=8800
TOTAL_PASSED=0
TOTAL_FAILED=0

# Build
echo "=== Building redin ==="
odin build "$ROOT_DIR/src/host" -out:"$BINARY"
echo ""

wait_for_server() {
  local timeout=10
  local start=$SECONDS
  while ! curl -s "http://localhost:$PORT/frames" >/dev/null 2>&1; do
    if (( SECONDS - start >= timeout )); then
      echo "ERROR: Dev server did not start within ${timeout}s"
      return 1
    fi
    sleep 0.2
  done
}

for test_file in "$SCRIPT_DIR"/test_*.bb; do
  name="$(basename "$test_file" .bb)"      # test_smoke
  app_name="${name#test_}"                  # smoke
  app_file="$SCRIPT_DIR/${app_name}_app.fnl"

  if [ ! -f "$app_file" ]; then
    echo "SKIP $name — no matching ${app_name}_app.fnl"
    continue
  fi

  echo "=== $name ==="

  # Start dev server in background
  "$BINARY" --dev "$app_file" &
  SERVER_PID=$!

  if ! wait_for_server; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    TOTAL_FAILED=$((TOTAL_FAILED + 1))
    echo ""
    continue
  fi

  # Run test
  if bb "$SCRIPT_DIR/run.bb" "$test_file"; then
    : # pass count comes from run.bb output
  else
    TOTAL_FAILED=$((TOTAL_FAILED + 1))
  fi

  # Shutdown
  curl -s -X POST "http://localhost:$PORT/shutdown" >/dev/null 2>&1 || true
  wait "$SERVER_PID" 2>/dev/null || true
  echo ""
done

echo "=== Done ==="
if [ "$TOTAL_FAILED" -gt 0 ]; then
  echo "$TOTAL_FAILED test suite(s) had failures"
  exit 1
else
  echo "All test suites passed"
fi
