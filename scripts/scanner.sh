#!/usr/bin/env bash
# scanner.sh — Discover Claude agents across tmux panes, output NDJSON
# Usage: scanner.sh [all|current] [session_name]
#   all     - scan all tmux sessions (default)
#   current - only scan the given session_name
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

SCOPE="${1:-all}"
CUR_SESSION="${2:-}"

SESSION_DIR="$HOME/.claude/sessions"
INTERVAL=$(get_opt "@agent-monitor-refresh-interval" "2")
SUMMARY_LINES=$(get_opt "@agent-monitor-summary-lines" "1")
NOW=$(date +%s)

# Collect pane_pids once for performance
PANE_PIDS="$(/usr/bin/tmux list-panes -a -F '#{pane_pid}' 2>/dev/null)"

output_agent() {
    local pid="$1" status="$2" cwd="$3" started_at="$4" waiting_for="$5"
    local target="$6" summary="$7"

    local uptime=$((NOW - started_at / 1000))
    local uptime_str
    uptime_str="$(format_uptime "$uptime")"

    # Status display: map "waiting" + waitingFor to display
    local display_status="$status"
    if [ "$status" = "waiting" ] && [ -n "$waiting_for" ] && [ "$waiting_for" != "null" ]; then
        display_status="waiting($waiting_for)"
    fi

    jq -nc --arg status "$display_status" \
           --arg agent "claude" \
           --arg cwd "$cwd" \
           --arg target "$target" \
           --arg uptime "$uptime_str" \
           --arg summary "$summary" \
        '{status: $status, agent: $agent, cwd: $cwd, target: $target, uptime: $uptime, summary: $summary}'
}

for session_file in "$SESSION_DIR"/*.json; do
    [ -f "$session_file" ] || continue

    pid=$(jq -r '.pid // empty' "$session_file" 2>/dev/null)
    [ -z "$pid" ] && continue

    # Stale check: process must be alive
    if ! kill -0 "$pid" 2>/dev/null; then
        continue
    fi

    status=$(jq -r '.status // "busy"' "$session_file" 2>/dev/null)
    cwd=$(jq -r '.cwd // empty' "$session_file" 2>/dev/null)
    started_at=$(jq -r '.startedAt // 0' "$session_file" 2>/dev/null)
    waiting_for=$(jq -r '.waitingFor // empty' "$session_file" 2>/dev/null)

    # Find ancestor pane_pid via PPid chain (validated in Phase 1)
    pane_pid=$(find_pane_pid "$pid")
    [ -z "$pane_pid" ] && continue

    target=$(pane_pid_to_target "$pane_pid")
    [ -z "$target" ] && continue

    # Filter by scope
    if [ "$SCOPE" = "current" ] && [ -n "$CUR_SESSION" ]; then
        target_session="${target%%.*}"
        target_session="${target_session%%:*}"
        if [ "$target_session" != "$CUR_SESSION" ]; then
            continue
        fi
    fi

    # Fallback cwd to pane_current_path
    if [ -z "$cwd" ] || [ "$cwd" = "null" ]; then
        cwd="$(/usr/bin/tmux display -t "$target" -p '#{pane_current_path}' 2>/dev/null)"
    fi

    # Summary: capture last N lines from target pane, strip ANSI/control chars
    summary=$(/usr/bin/tmux capture-pane -p -t "$target" 2>/dev/null \
        | tail -n "$SUMMARY_LINES" \
        | strip_ansi \
        | tr '\n' ' ' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    output_agent "$pid" "$status" "$cwd" "$started_at" "$waiting_for" "$target" "$summary"
done
