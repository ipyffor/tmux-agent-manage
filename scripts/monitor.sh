#!/usr/bin/env bash
# monitor.sh — fzf list + live preview + switch
# Usage: monitor.sh [all|current]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# If launched via run-shell (no TTY), re-launch in a new tmux window
if [ ! -t 0 ]; then
    exec /usr/bin/tmux new-window "$0" "$@"
fi

source "$SCRIPT_DIR/helpers.sh"
require_deps

SCOPE="${1:-all}"
CUR_SESSION=""
if [ "$SCOPE" = "current" ]; then
    CUR_SESSION="$(/usr/bin/tmux display -p '#{session_name}' 2>/dev/null)"
fi

INTERVAL=$(get_opt "@agent-monitor-refresh-interval" "2")
FZF_EXTRA=$(get_opt "@agent-monitor-fzf-args" "")

RELOAD_CMD="bash -c \"source $SCRIPT_DIR/helpers.sh && $SCRIPT_DIR/scanner.sh $SCOPE $CUR_SESSION | format_stream\""

# Initial data
INIT_DATA=$("$SCRIPT_DIR/scanner.sh" "$SCOPE" "$CUR_SESSION" | format_stream)
if [ -z "$INIT_DATA" ]; then
    echo "No agents running. Press enter to exit."
    read -r
    exit 0
fi

MONITOR_PANE="$(/usr/bin/tmux display -p '#{pane_id}' 2>/dev/null)"
FZF_PORT=$((50000 + RANDOM % 15000))

(
    # Background reload loop
    (
        last_struct=""
        cycle=0
        while true; do
            sleep "$INTERVAL"
            if [ "$(/usr/bin/tmux display -p -t "$MONITOR_PANE" '#{pane_active}' 2>/dev/null)" = "0" ]; then
                continue
            fi
            new_struct=$(bash -c "source $SCRIPT_DIR/helpers.sh && $SCRIPT_DIR/scanner.sh $SCOPE $CUR_SESSION" 2>/dev/null \
                | jq -r '"\(.target):\(.status)"' 2>/dev/null | sort)
            cycle=$((cycle + 1))
            if [ "$new_struct" != "$last_struct" ] || [ $((cycle % 5)) -eq 0 ]; then
                [ "$new_struct" != "$last_struct" ] && last_struct="$new_struct"
                body="reload($RELOAD_CMD)"
                exec 3<>/dev/tcp/127.0.0.1/$FZF_PORT 2>/dev/null || continue
                printf 'POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: %d\r\n\r\n%s' \
                    "${#body}" "$body" >&3
                exec 3>&-
            fi
        done
    ) &
    RELOAD_PID=$!
    trap "kill $RELOAD_PID 2>/dev/null" EXIT

    HEADER="$(printf '\033[2m%-15s%-8s%-35s%8s %s\033[0m' 'STATUS' 'AGENT' 'CWD' 'UPTIME' 'SUMMARY')"

    echo "$INIT_DATA" | fzf \
        --header="$HEADER" \
        --listen="127.0.0.1:$FZF_PORT" \
        --delimiter=$'\t' \
        --with-nth=1 \
        --id-nth=2 \
        --track \
        --preview "$SCRIPT_DIR/preview.sh {3}" \
        --preview-window "down:80%:wrap" \
        --bind "enter:execute($SCRIPT_DIR/switch.sh \$(echo {3} | jq -r .target))+abort" \
        --bind "esc:abort" \
        --bind "ctrl-r:reload($RELOAD_CMD)" \
        --ansi \
        --layout=reverse \
        $FZF_EXTRA
)
