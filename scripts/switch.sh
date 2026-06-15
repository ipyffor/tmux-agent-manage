#!/usr/bin/env bash
# switch.sh — Jump to target tmux pane (cross-session)
# Usage: switch.sh <session>:<window>.<pane>
set -euo pipefail

TARGET="${1:-}"

if [ -z "$TARGET" ]; then
    echo "Usage: switch.sh <session>:<window>.<pane>" >&2
    exit 1
fi

# Parse: session:window.pane
SESSION="${TARGET%%:*}"
rest="${TARGET#*:}"
WINDOW="${rest%%.*}"
PANE="${rest#*.}"

/usr/bin/tmux switch-client -t "$SESSION" \; \
    select-window -t "$SESSION:$WINDOW" \; \
    select-pane -t "$SESSION:$WINDOW.$PANE" 2>/dev/null
