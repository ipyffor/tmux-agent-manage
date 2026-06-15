#!/usr/bin/env bash
# preview.sh — fzf preview: show live pane content for a target
set -euo pipefail

INPUT="${1:-}"

target=$(echo "$INPUT" | jq -r '.target // empty' 2>/dev/null || true)

if [ -z "$target" ]; then
    echo "(no target)"
    exit 0
fi

/usr/bin/tmux capture-pane -ep -t "$target" 2>/dev/null
