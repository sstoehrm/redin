#!/usr/bin/env bash
# Run all UI integration tests.
# Each test_<name>.bb is paired with <name>_app.fnl.
# The script builds redin, then for each pair starts the dev server,
# waits for it to be ready, runs the test, and shuts it down.
#
# Flags:
#   --headless   Run each app under xvfb-run so no real display is required.
#                Useful for CI and SSH sessions. Requires `xvfb-run` on PATH.

set -euo pipefail

HEADLESS=0
for arg in "$@"; do
  case "$arg" in
    --headless) HEADLESS=1 ;;
    -h|--help)
      sed -n '2,10p' "$0"
      exit 0
      ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

LAUNCHER=()
if [ "$HEADLESS" -eq 1 ]; then
  if ! command -v xvfb-run >/dev/null 2>&1; then
    echo "ERROR: --headless requires xvfb-run (apt-get install xvfb)" >&2
    exit 2
  fi
  # -a: auto-assign a free display; -s: quiet, 24-bit RGB, 1280x800 (covers
  # tests that resize up to 1280 wide).
  LAUNCHER=(xvfb-run -a -s "-screen 0 1280x800x24")
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BINARY="$ROOT_DIR/build/redin"
PORT_FILE="$ROOT_DIR/.redin-port"
TOKEN_FILE="$ROOT_DIR/.redin-token"
PORT=""
TOKEN=""
TOTAL_PASSED=0
TOTAL_FAILED=0

# Per-test and total wall-clock budgets (#132). Defaults are tight on
# purpose: a healthy test runs in seconds, so 30s catches a hang fast,
# and a 120s total cap keeps a runaway suite from pinning CI for hours
# while still leaving room for the fast-path of 25-ish tests.
TEST_TIMEOUT="${REDIN_TEST_TIMEOUT:-30}"
GLOBAL_TIMEOUT="${REDIN_GLOBAL_TIMEOUT:-120}"
GLOBAL_START=$SECONDS

# Build
echo "=== Building redin ==="
( cd "$ROOT_DIR" && ./build-dev.sh )
echo ""

wait_for_server() {
  local timeout=10
  local start=$SECONDS
  while true; do
    if [ -f "$PORT_FILE" ] && [ -f "$TOKEN_FILE" ]; then
      PORT="$(cat "$PORT_FILE")"
      TOKEN="$(cat "$TOKEN_FILE")"
      if [ -n "$PORT" ] && [ -n "$TOKEN" ] \
         && curl -s -H "Authorization: Bearer $TOKEN" \
                 "http://localhost:$PORT/frames" >/dev/null 2>&1; then
        return 0
      fi
    fi
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

  if (( SECONDS - GLOBAL_START >= GLOBAL_TIMEOUT )); then
    echo "GLOBAL TIMEOUT: suite exceeded ${GLOBAL_TIMEOUT}s; remaining tests skipped (#132)" >&2
    TOTAL_FAILED=$((TOTAL_FAILED + 1))
    break
  fi

  if [ ! -f "$app_file" ]; then
    echo "SKIP $name — no matching ${app_name}_app.fnl"
    continue
  fi

  echo "=== $name ==="

  # Optional sidecar: <app>_app.flags — whitespace-split extra host flags.
  flags_file="$SCRIPT_DIR/${app_name}_app.flags"
  extra_flags=()
  if [ -f "$flags_file" ]; then
    # shellcheck disable=SC2207
    extra_flags=( $(cat "$flags_file") )
  fi

  # Start dev server in background
  rm -f "$PORT_FILE"
  "${LAUNCHER[@]}" "$BINARY" "${extra_flags[@]}" "$app_file" &
  SERVER_PID=$!

  if ! wait_for_server; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    TOTAL_FAILED=$((TOTAL_FAILED + 1))
    echo ""
    continue
  fi

  # Run test — bound with `timeout` so a hung HTTP call against the dev
  # server can't stall the whole suite. The bb http helpers in
  # redin_test.bb don't all carry a per-request deadline, and the runner
  # used to silently absorb a stuck test until GitHub's 6h job cap
  # kicked in (#132). Surface the offender by name instead.
  if timeout --foreground "$TEST_TIMEOUT" bb "$SCRIPT_DIR/run.bb" "$test_file"; then
    : # pass count comes from run.bb output
  else
    rc=$?
    if [ "$rc" -eq 124 ]; then
      echo "TIMEOUT: $name exceeded ${TEST_TIMEOUT}s — likely a hung HTTP call (#132)" >&2
    fi
    TOTAL_FAILED=$((TOTAL_FAILED + 1))
  fi

  # Shutdown — issue /shutdown, then bound the wait. Issue #131
  # tracks an intermittent dev-build hang where /shutdown returns
  # 200 but the process doesn't exit; force-kill after the deadline
  # so the suite cannot stall.
  #
  # --max-time 3 is the load-bearing piece for #132: without it, an
  # unresponsive dev server leaves curl waiting forever (no default
  # request timeout), and the kill -0 / kill -9 loop below never runs.
  curl -s --max-time 3 -X POST -H "Authorization: Bearer $TOKEN" \
       "http://localhost:$PORT/shutdown" >/dev/null 2>&1 || true
  for i in 1 2 3 4 5; do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then break; fi
    sleep 1
  done
  if kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "WARN: $name dev server did not exit after /shutdown; force-killing (#131)" >&2
    kill -9 "$SERVER_PID" 2>/dev/null || true
  fi
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
