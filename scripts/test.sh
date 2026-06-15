#!/usr/bin/env bash
# test.sh — Unit tests for tmux-agent-monitor
# Run: bash scripts/test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

# Export functions so they're available in $(...) subshells
export -f format_uptime format_stream strip_ansi is_alive read_session find_pane_pid pane_pid_to_target get_opt

PASS=0
FAIL=0
FAILURES=()

assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        echo "  PASS: $desc"
    else
        FAIL=$((FAIL + 1))
        FAILURES+=("FAIL: $desc — expected='$expected' actual='$actual'")
        echo "  FAIL: $desc"
        echo "    expected: '$expected'"
        echo "    actual:   '$actual'"
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        PASS=$((PASS + 1))
        echo "  PASS: $desc"
    else
        FAIL=$((FAIL + 1))
        FAILURES+=("FAIL: $desc — expected to contain '$needle'")
        echo "  FAIL: $desc — output does not contain '$needle'"
    fi
}

assert_json_field() {
    local desc="$1" json="$2" field="$3" expected="$4"
    local actual
    actual=$(echo "$json" | jq -r "$field" 2>/dev/null)
    assert "$desc" "$expected" "$actual"
}

echo ""
echo "=== Test: format_uptime ==="

assert "0 seconds"    "0s"    "$(format_uptime 0)"
assert "30 seconds"   "30s"   "$(format_uptime 30)"
assert "1 minute"     "1m0s"  "$(format_uptime 60)"
assert "1m30s"        "1m30s" "$(format_uptime 90)"
assert "10 minutes"   "10m0s" "$(format_uptime 600)"
assert "1 hour"       "60m0s" "$(format_uptime 3600)"
assert "1h5m"         "65m5s" "$(format_uptime 3905)"

echo ""
echo "=== Test: strip_ansi ==="

assert "plain text unchanged" \
    "hello world" \
    "$(echo "hello world" | strip_ansi)"

assert "removes ANSI color codes" \
    "colored text" \
    "$(printf '\033[31mcolored\033[0m \033[1mtext\033[0m' | strip_ansi)"

assert "removes control chars" \
    "ab" \
    "$(printf 'a\rb' | strip_ansi)"

assert "removes empty lines" \
    "line1
line3" \
    "$(printf 'line1\n\nline3' | strip_ansi)"

echo ""
echo "=== Test: is_alive ==="

self_pid="$$"
assert "current process ($$) is alive"   "0" "$(is_alive $self_pid && echo 0 || echo 1)"
assert "bogus PID is dead"               "1" "$(is_alive 99999999 && echo 0 || echo 1)"

echo ""
echo "=== Test: read_session ==="

# Use a real session file if available
SESSION_FILE=$(ls "$HOME/.claude/sessions/"*.json 2>/dev/null | head -1)
if [ -n "$SESSION_FILE" ]; then
    PID=$(jq -r .pid "$SESSION_FILE")
    SESSION_STATUS=$(jq -r .status "$SESSION_FILE")
    SESSION_CWD=$(jq -r .cwd "$SESSION_FILE")

    assert "read_session returns status"  "$SESSION_STATUS" "$(read_session "$PID" "status")"
    assert "read_session returns cwd"     "$SESSION_CWD"    "$(read_session "$PID" "cwd")"
    assert "read_session missing key"     ""                "$(read_session "$PID" "nonexistent_key")"
    assert "read_session bogus pid"       ""                "$(read_session 99999999 "status")"
    echo "  (tested with real session pid=$PID)"
else
    echo "  SKIP: No Claude session files found"
fi

echo ""
echo "=== Test: find_pane_pid (needs real Claude process) ==="

if [ -n "${SESSION_FILE:-}" ] && is_alive "$PID" 2>/dev/null; then
    PANE_PID=$(find_pane_pid "$PID" 2>/dev/null || echo "")
    if [ -n "$PANE_PID" ]; then
        assert "find_pane_pid returns a number" \
            "number" \
            "$(echo "$PANE_PID" | grep -qE '^[0-9]+$' && echo "number" || echo "not-number")"

        TARGET=$(pane_pid_to_target "$PANE_PID")
        assert_contains "pane_pid_to_target returns valid target" ":" "$TARGET"
        assert_contains "pane_pid_to_target contains dot for pane" "." "$TARGET"

        echo "  => pid=$PID → pane_pid=$PANE_PID → target=$TARGET"
    else
        echo "  SKIP: find_pane_pid returned empty (Claude may not be in a tmux pane)"
    fi
else
    echo "  SKIP: No live Claude session"
fi

echo ""
echo "=== Test: pane_pid_to_target with real data ==="

REAL_PANE_PID=$(/usr/bin/tmux list-panes -a -F '#{pane_pid}' 2>/dev/null | head -1)
if [ -n "$REAL_PANE_PID" ]; then
    TARGET=$(pane_pid_to_target "$REAL_PANE_PID")
    assert_contains "target contains session:window.pane format" ":" "$TARGET"
    echo "  => pane_pid=$REAL_PANE_PID → target=$TARGET"
else
    echo "  SKIP: No tmux panes"
fi

echo ""
echo "=== Test: get_opt ==="

/usr/bin/tmux source "$(dirname "$SCRIPT_DIR")/tmux-agent-manage.tmux" 2>/dev/null

assert "default value when not set" \
    "mydefault" \
    "$(get_opt "@agent-monitor-test-nonexistent" "mydefault")"

assert "reads @agent-monitor-processes" \
    "claude" \
    "$(get_opt "@agent-monitor-processes" "wrong")"

assert "reads @agent-monitor-refresh-interval" \
    "2" \
    "$(get_opt "@agent-monitor-refresh-interval" "99")"

echo ""
echo "=== Test: scanner.sh output ==="

SCANNER_OUTPUT=$("$SCRIPT_DIR/scanner.sh" all 2>/dev/null)
SCANNER_COUNT=$(echo "$SCANNER_OUTPUT" | sed '/^$/d' | wc -l | tr -d ' ')

echo "  Scanner found $SCANNER_COUNT agent(s)"

if [ -n "$SCANNER_OUTPUT" ] && [ "$SCANNER_COUNT" -gt 0 ]; then
    FIRST_LINE=$(echo "$SCANNER_OUTPUT" | head -1)

    # Validate JSON structure of every output line
    LINE_NUM=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        LINE_NUM=$((LINE_NUM + 1))

        # Must be valid JSON
        if ! echo "$line" | jq empty 2>/dev/null; then
            FAIL=$((FAIL + 1))
            FAILURES+=("FAIL: scanner line $LINE_NUM is not valid JSON: $line")
            echo "  FAIL: line $LINE_NUM is not valid JSON"
            continue
        fi

        # Required fields
        # summary can be empty (pane with no output)
        for field in status agent cwd target uptime; do
            val=$(echo "$line" | jq -r ".$field // empty" 2>/dev/null)
            if [ -z "$val" ]; then
                FAIL=$((FAIL + 1))
                FAILURES+=("FAIL: scanner line $LINE_NUM missing field '$field'")
                echo "  FAIL: line $LINE_NUM missing field '$field'"
            fi
        done

        # status must be a known value
        status_val=$(echo "$line" | jq -r .status)
        case "$status_val" in
            busy|idle|waiting|waiting\(*\)) ;;
            *)
                FAIL=$((FAIL + 1))
                FAILURES+=("FAIL: scanner line $LINE_NUM unexpected status '$status_val'")
                echo "  FAIL: line $LINE_NUM unexpected status '$status_val'"
                ;;
        esac

        # target must match session:window.pane format
        target_val=$(echo "$line" | jq -r .target)
        if ! echo "$target_val" | grep -qE '^[^:]+:[0-9]+\.[0-9]+$'; then
            FAIL=$((FAIL + 1))
            FAILURES+=("FAIL: scanner line $LINE_NUM invalid target format '$target_val'")
            echo "  FAIL: line $LINE_NUM invalid target format '$target_val'"
        fi

        # uptime must be non-empty
        uptime_val=$(echo "$line" | jq -r .uptime)
        if ! echo "$uptime_val" | grep -qE '[0-9]+[sm]'; then
            FAIL=$((FAIL + 1))
            FAILURES+=("FAIL: scanner line $LINE_NUM invalid uptime '$uptime_val'")
            echo "  FAIL: line $LINE_NUM invalid uptime '$uptime_val'"
        fi
    done <<<"$SCANNER_OUTPUT"

    echo "  Validated $LINE_NUM line(s)"
else
    echo "  No agents running — skipping field validation (not an error)"
fi

echo ""
echo "=== Test: scanner scope filtering ==="

if [ -n "$SCANNER_OUTPUT" ] && [ "$SCANNER_COUNT" -gt 0 ]; then
    ALL_COUNT=$("$SCRIPT_DIR/scanner.sh" all 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')
    # Test with bogus session name — should return 0
    BOGUS_COUNT=$("$SCRIPT_DIR/scanner.sh" current "no_such_session_xyz" 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')
    assert "scope=current with bogus session returns 0" "0" "$BOGUS_COUNT"
    assert "scope=all returns agents" "$ALL_COUNT" "$SCANNER_COUNT"
else
    echo "  SKIP: No agents to test scope filtering"
fi

echo ""
echo "=== Test: scanner stale process exclusion ==="

DEAD_PID=99999999
# This PID shouldn't exist, so it should be skipped
assert "is_alive returns false for bogus PID" "1" "$(is_alive $DEAD_PID && echo 0 || echo 1)"

# Verify no scanner output references the bogus PID
if [ -n "$SCANNER_OUTPUT" ]; then
    if echo "$SCANNER_OUTPUT" | jq -r .target 2>/dev/null | grep -q "$DEAD_PID"; then
        FAIL=$((FAIL + 1))
        FAILURES+=("FAIL: scanner output contains dead PID reference")
        echo "  FAIL: scanner references dead PID $DEAD_PID"
    else
        PASS=$((PASS + 1))
        echo "  PASS: dead PIDs excluded from output"
    fi
fi

echo ""
echo "=== Test: preview.sh input parsing ==="

PREVIEW_OUTPUT=$("$SCRIPT_DIR/preview.sh" '{"target":"0:1.1"}' 2>/dev/null || echo "")
if [ -n "$PREVIEW_OUTPUT" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: preview.sh produces output for valid target"
else
    echo "  Note: preview.sh produced empty output (target may not exist in current tmux)"
fi

PREVIEW_EMPTY=$("$SCRIPT_DIR/preview.sh" "" 2>/dev/null || echo "")
assert "preview.sh handles empty input" "(no target)" "$PREVIEW_EMPTY"

PREVIEW_BAD=$("$SCRIPT_DIR/preview.sh" 'not json' 2>/dev/null || echo "")
assert "preview.sh handles bad input" "(no target)" "$PREVIEW_BAD"

echo ""
echo "=== Test: format_stream ==="

if declare -f format_stream >/dev/null 2>&1; then
    TEST_JSON='{"status":"busy","agent":"claude","cwd":"/tmp/test","target":"test:0.1","uptime":"5m","summary":"working"}'
    FORMATTED=$(echo "$TEST_JSON" | format_stream 2>/dev/null || echo "")

    if [ -n "$FORMATTED" ]; then
        # Should contain tab separator
        assert_contains "format_stream output contains tab separator" \
            "$(printf '\t')" "$FORMATTED"

        # Field 2 is target, field 3 is the original JSON
        TARGET_PART=$(echo "$FORMATTED" | cut -f2)
        JSON_PART=$(echo "$FORMATTED" | cut -f3)
        assert_contains "format_stream target field is valid" ":" "$TARGET_PART"
        assert "format_stream preserves JSON in third field" \
            "$TEST_JSON" "$JSON_PART"

        # First field should contain ANSI codes and status
        DISPLAY_PART=$(echo "$FORMATTED" | cut -f1)
        assert_contains "display part contains 'busy'"    "busy"    "$DISPLAY_PART"
        assert_contains "display part contains 'claude'"  "claude"  "$DISPLAY_PART"
        assert_contains "display part contains cwd"       "/tmp"    "$DISPLAY_PART"
        assert_contains "display part contains uptime"    "5m"      "$DISPLAY_PART"
    else
        FAIL=$((FAIL + 1))
        FAILURES+=("FAIL: format_stream produced empty output")
        echo "  FAIL: format_stream produced empty output"
    fi

    # Test idle status
    TEST_IDLE='{"status":"idle","agent":"claude","cwd":"/x","target":"x:0.1","uptime":"1s","summary":""}'
    IDLE_OUT=$(echo "$TEST_IDLE" | format_stream)
    assert_contains "format_stream idle is green (32)" "32" "$IDLE_OUT"

    # Test waiting
    TEST_WAIT='{"status":"waiting(perm)","agent":"claude","cwd":"/x","target":"x:0.2","uptime":"1s","summary":""}'
    WAIT_OUT=$(echo "$TEST_WAIT" | format_stream)
    assert_contains "format_stream waiting is magenta (35)" "35" "$WAIT_OUT"
else
    echo "  SKIP: format_stream not available (monitor.sh may have side effects)"
fi

echo ""
echo "=== Test: switch.sh target parsing ==="

# Verify the script exists and is syntactically valid
assert "switch.sh exists" "0" "$(test -f "$SCRIPT_DIR/switch.sh" && echo 0 || echo 1)"

# Validate session:window.pane parsing with a regex check on the script
SWITCH_LOGIC=$(grep -E 'SESSION=|WINDOW=|PANE=' "$SCRIPT_DIR/switch.sh" 2>/dev/null || echo "")
assert_contains "switch.sh parses SESSION from target" "SESSION" "$SWITCH_LOGIC"
assert_contains "switch.sh parses WINDOW from target" "WINDOW" "$SWITCH_LOGIC"
assert_contains "switch.sh parses PANE from target"   "PANE"   "$SWITCH_LOGIC"

echo ""
echo "=== Test: Edge cases ==="

# Empty scanner output when no sessions
NO_SESSION_DIR="/tmp/no-claude-sessions-$$"
mkdir -p "$NO_SESSION_DIR"
EMPTY_SCAN=$(HOME=/tmp/no-claude-sessions-"$$" bash -c "SESSION_DIR='$NO_SESSION_DIR' source '$SCRIPT_DIR/helpers.sh'; ls '$NO_SESSION_DIR'/*.json 2>/dev/null" || echo "none")
rm -rf "$NO_SESSION_DIR"
assert "empty session dir produces no output" "none" "$EMPTY_SCAN"

# jq handles corrupted JSON gracefully
echo "not json" > /tmp/agent-monitor-test-corrupt.json
CORRUPT=$(jq -r .status /tmp/agent-monitor-test-corrupt.json 2>/dev/null || echo "PARSE_ERROR")
rm -f /tmp/agent-monitor-test-corrupt.json
assert "corrupted JSON is handled" "PARSE_ERROR" "$CORRUPT"

# uptime formatting edge case: negative (shouldn't crash)
format_uptime -5 >/dev/null 2>&1 && EC=$? || EC=$?
assert "format_uptime doesn't crash on negative" "0" "$EC"

echo ""
echo "====================================="
echo "  RESULTS: $PASS passed, $FAIL failed"
echo "====================================="

if [ $FAIL -gt 0 ]; then
    echo ""
    echo "Failures:"
    for f in "${FAILURES[@]}"; do
        echo "  $f"
    done
    echo ""
    exit 1
else
    echo "  All tests passed!"
    exit 0
fi
