#!/usr/bin/env bash
set -e

PASS=0
FAIL=0

mcp_call() {
    local id=$1
    local method=$2
    local params=$3
    echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"method\":\"$method\",\"params\":$params}"
}

INIT='{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'

run_test() {
    local desc=$1
    local input=$2
    local check=$3

    result=$(echo "$input" | bb mcp/redin-mcp.bb 2>/dev/null | tail -1)
    if echo "$result" | grep -q "$check"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "    Expected to contain: $check"
        echo "    Got: $(echo "$result" | head -c 200)"
        FAIL=$((FAIL + 1))
    fi
}

echo "Testing MCP server..."

# Protocol tests (no dev server needed)
run_test "initialize" "$INIT" '"protocolVersion"'

run_test "tools/list has 4 tools" "$INIT
$(mcp_call 1 tools/list '{}')" '"inspect"'

run_test "tools/list has act" "$INIT
$(mcp_call 1 tools/list '{}')" '"act"'

run_test "tools/list has screenshot" "$INIT
$(mcp_call 1 tools/list '{}')" '"screenshot"'

run_test "tools/list has theme" "$INIT
$(mcp_call 1 tools/list '{}')" '"theme"'

run_test "resources/list" "$INIT
$(mcp_call 1 resources/list '{}')" '"redin://docs'

run_test "resources/read placeholder" "$INIT
$(mcp_call 1 resources/read '{"uri":"redin://docs/quickstart"}')" '"text"'

run_test "unknown method returns error" "$INIT
$(mcp_call 1 bogus/method '{}')" '"error"'

# Integration tests (need dev server)
if curl -s http://localhost:8800/frames > /dev/null 2>&1; then
    echo ""
    echo "Dev server detected, running integration tests..."

    run_test "inspect frame" "$INIT
$(mcp_call 1 tools/call '{"name":"inspect","arguments":{"what":"frame"}}')" '"content"'

    run_test "inspect aspects" "$INIT
$(mcp_call 1 tools/call '{"name":"inspect","arguments":{"what":"aspects"}}')" '"content"'

    run_test "theme read" "$INIT
$(mcp_call 1 tools/call '{"name":"theme","arguments":{"action":"read"}}')" '"content"'
else
    echo ""
    echo "Dev server not running, skipping integration tests"
fi

echo ""
echo "$PASS passed, $FAIL failed"
exit $FAIL
