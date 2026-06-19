#!/usr/bin/env bash
# refresh-feed.sh — Run scanner + format for fzf reload
# Args: scope session_name monitor_pane_id
# Checks pane_active before scanning.
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

SCOPE="${1:-all}"
SESSION_NAME="${2:-}"
MONITOR_PANE="${3:-}"

# Visibility check — only scan when monitor pane is active
if [ -n "$MONITOR_PANE" ]; then
    active=$(t display-message -t "$MONITOR_PANE" -p '#{pane_active}' 2>/dev/null || echo "0")
    if [ "$active" != "1" ]; then
        exit 0
    fi
fi

"$SCRIPT_DIR/scanner.sh" "$SCOPE" "$SESSION_NAME" 2>/dev/null | format_stream

exit 0
