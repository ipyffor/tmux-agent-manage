#!/usr/bin/env bash
# switch.sh — Jump to the target agent's tmux pane (cross-session)
# Input: pane_id (%N)
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

PANE_ID="${1:-}"

if [ -z "$PANE_ID" ]; then
    echo "Usage: switch.sh <pane_id>" >&2
    exit 1
fi

# Resolve pane_id → session:window.pane
# Primary: display-message -t %N
TARGET=$(t display-message -t "$PANE_ID" -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)

# Fallback: grep list-panes
if [ -z "$TARGET" ]; then
    TARGET=$(t list-panes -a -F '#{pane_id} #{session_name}:#{window_index}.#{pane_index}' 2>/dev/null \
        | awk -v id="$PANE_ID" '$1==id{print $2; exit}')
fi

if [ -z "$TARGET" ]; then
    echo "ERROR: Could not resolve pane_id $PANE_ID to session:window.pane" >&2
    exit 1
fi

# Parse target into components
SESSION="${TARGET%%:*}"
rest="${TARGET#*:}"
WIN="${rest%.*}"
PANE="${rest##*.}"

# Switch client to the target session, then select window and pane
t switch-client -t "$SESSION" \; \
    select-window -t "${SESSION}:${WIN}" \; \
    select-pane -t "${SESSION}:${WIN}.${PANE}" \
    2>/dev/null || {
    echo "ERROR: Failed to switch to $TARGET" >&2
    exit 1
}

exit 0
