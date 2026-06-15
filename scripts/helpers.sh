#!/usr/bin/env bash
# Shared functions for tmux-agent-monitor
set -euo pipefail

# Read a @agent-monitor-* option with a default value
get_opt() {
    local name="$1" default="$2"
    local val
    val="$(/usr/bin/tmux show-option -gqv "$name" 2>/dev/null)"
    echo "${val:-$default}"
}

# Check required dependencies, exit with error if missing
require_deps() {
    local missing=()
    for dep in fzf jq; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "ERROR: tmux-agent-monitor requires: ${missing[*]}" >&2
        echo "Install with: sudo apt install ${missing[*]}" >&2
        exit 1
    fi
}

# Read a session status file and extract fields
# Returns empty string if file doesn't exist or pid is dead
read_session() {
    local pid="$1"
    local key="$2"
    local file="$HOME/.claude/sessions/${pid}.json"
    if [ ! -f "$file" ]; then
        echo ""
        return
    fi
    jq -r ".${key} // empty" "$file" 2>/dev/null
}

# Check if a process is alive
is_alive() {
    local pid="$1"
    kill -0 "$pid" 2>/dev/null
}

# Walk the parent PID chain from a given pid upward,
# match against /usr/bin/tmux pane_pid list, return the matching
# pane_pid or empty string if not found.
find_pane_pid() {
    local pid="$1"
    local cur="$pid"
    local pane_pids
    pane_pids="$(/usr/bin/tmux list-panes -a -F '#{pane_pid}' 2>/dev/null)"

    while [ "$cur" -gt 1 ]; do
        if echo "$pane_pids" | grep -q "^${cur}$"; then
            echo "$cur"
            return 0
        fi
        local ppid
        ppid=$(awk '/^PPid:/{print $2}' "/proc/${cur}/status" 2>/dev/null)
        if [ -z "$ppid" ] || [ "$ppid" = "$cur" ]; then
            break
        fi
        cur="$ppid"
    done
    return 1
}

# Given a pane_pid, return the target string "session:window.pane"
pane_pid_to_target() {
    local pane_pid="$1"
    /usr/bin/tmux list-panes -a -F '#{pane_pid} #{session_name}:#{window_index}.#{pane_index}' 2>/dev/null \
        | awk -v pid="$pane_pid" '$1 == pid {print $2; exit}'
}

# Strip ANSI escape sequences and control characters from stdin
strip_ansi() {
    sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\000-\010\013-\037' | sed '/^$/d'
}

# Human-readable uptime from seconds
format_uptime() {
    local secs="$1"
    local m=$((secs / 60))
    local s=$((secs % 60))
    if [ "$m" -gt 0 ]; then
        printf "%dm%ds" "$m" "$s"
    else
        printf "%ds" "$s"
    fi
}

# Format a JSON line into: display + TAB + target + TAB + raw JSON (for fzf --track)
# Column widths:  STATUS=15  AGENT=8  CWD=35  UPTIME=8  SUMMARY=rest
format_stream() {
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local status=$(echo "$line" | jq -r '.status // "?"')
        local agent=$(echo "$line" | jq -r '.agent // "?"')
        local cwd_raw=$(echo "$line" | jq -r '.cwd // "?"')
        local uptime=$(echo "$line" | jq -r '.uptime // "?"')
        local summary=$(echo "$line" | jq -r '.summary // ""')
        local target=$(echo "$line" | jq -r '.target // ""')

        local color
        case "$status" in
            busy)      color="33" ;;
            idle)      color="32" ;;
            waiting*)  color="35" ;;
            *)         color="37" ;;
        esac

        # Truncate cwd from left if too long: show last 34 chars with "…" prefix
        local cwd="$cwd_raw"
        if [ "${#cwd}" -gt 35 ]; then
            cwd=">${cwd: -34}"
        fi

        # Pad columns FIRST (plain text), then apply ANSI colors
        local status_col agent_col cwd_col uptime_col
        status_col=$(printf '%-15s' "$status")
        agent_col=$(printf '%-8s' "$agent")
        cwd_col=$(printf '%-35s' "$cwd")
        uptime_col=$(printf '%8s' "$uptime")

        printf "\033[1;${color}m%s\033[0m" "$status_col"
        printf "%s" "$agent_col"
        printf "%s" "$cwd_col"
        printf "\033[2m%s\033[0m" "$uptime_col"
        printf " %s" "$summary"
        # hidden fields: target + JSON for fzf
        printf "\t%s\t%s\n" "$target" "$line"
    done
}
