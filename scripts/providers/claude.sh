#!/usr/bin/env bash
# claude.sh — Claude provider: scans ~/.claude/sessions/*.json for live agents
# Outputs NDJSON on stdout: one agent per line
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../helpers.sh"

SUMMARY_LINES=$(get_opt "@agent-monitor-summary-lines" "1")
NOW=$(($(date +%s%N 2>/dev/null || echo $(($(date +%s) * 1000000000))) / 1000000))

for session_file in "$SESSIONS_DIR"/*.json; do
    [ -e "$session_file" ] || continue

    # Extract PID from filename (<pid>.json)
    fname=$(basename "$session_file")
    pid="${fname%.json}"

    # Validate PID is numeric
    [[ "$pid" =~ ^[0-9]+$ ]] || continue

    # Liveness check
    if ! is_alive "$pid"; then
        continue
    fi

    # PID → pane_id (primary: TMUX_PANE env)
    pane_id=$(pane_id_from_pid "$pid")

    # Fallback: PPid chain
    if [ -z "$pane_id" ]; then
        pane_pid=$(find_pane_pid "$pid" 2>/dev/null || true)
        if [ -n "$pane_pid" ]; then
            # Convert pane_pid → pane_id
            pane_id=$(t list-panes -a -F '#{pane_id} #{pane_pid}' 2>/dev/null \
                | awk -v pp="$pane_pid" '$2==pp{print $1; exit}')
        fi
    fi

    # If still no pane_id, this agent is not in a tmux pane
    [ -n "$pane_id" ] || continue

    # Parse JSON fields
    status=$(jq -r '.status // "unknown"' "$session_file" 2>/dev/null || echo "unknown")
    cwd=$(jq -r '.cwd // "?"' "$session_file" 2>/dev/null || echo "?")
    started_at=$(jq -r '.startedAt // 0' "$session_file" 2>/dev/null || echo 0)

    # Calculate uptime
    uptime_secs=0
    if [ "$started_at" -gt 0 ] 2>/dev/null; then
        # startedAt is in milliseconds
        uptime_ms=$((NOW - started_at))
        uptime_secs=$((uptime_ms / 1000))
        [ "$uptime_secs" -lt 0 ] && uptime_secs=0
    fi
    uptime=$(format_uptime "$uptime_secs")

    # Resolve pane_id → session:window.pane target
    target=$(pane_id_to_target "$pane_id")

    # Capture-pane for summary (last N lines)
    summary=$(t capture-pane -p -e -t "$pane_id" -S "-$SUMMARY_LINES" 2>/dev/null \
        | strip_ansi \
        | tail -n "$SUMMARY_LINES" \
        | paste -sd ' ' - 2>/dev/null || echo "")
    # Collapse whitespace and trim
    summary=$(echo "$summary" | sed 's/[[:space:]]\+/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//')

    # Output NDJSON
    jq -nc \
        --arg pane_id "$pane_id" \
        --arg agent "claude" \
        --arg status "$status" \
        --arg cwd "$cwd" \
        --arg started_at "$started_at" \
        --arg uptime "$uptime" \
        --arg summary "$summary" \
        --arg target "$target" \
        '{pane_id: $pane_id, agent: $agent, status: $status, cwd: $cwd, started_at: $started_at, uptime: $uptime, summary: $summary, target: $target}'
done

exit 0
