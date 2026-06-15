#!/usr/bin/env bash
# Validate PID→pane mapping: from Claude sessions, trace ppid chain to pane_pid.
# Run: bash scripts/validate-pid-pane.sh
set -uo pipefail  # no -e for validation script

TMUX_BIN="/usr/bin/tmux"
SESSION_DIR="$HOME/.claude/sessions"

echo "=== PID→pane Mapping Validation ==="
echo ""

pane_pids="$(/usr/bin/tmux list-panes -a -F '#{pane_pid}' 2>/dev/null)"

for session_file in "$SESSION_DIR"/*.json; do
    [ -f "$session_file" ] || continue

    pid=$(jq -r .pid "$session_file" 2>/dev/null)
    status=$(jq -r .status "$session_file" 2>/dev/null)
    cwd=$(jq -r .cwd "$session_file" 2>/dev/null)

    echo "Claude pid=$pid status=$status cwd=$cwd"

    # Check alive
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "  => DEAD (skip)"
        echo ""
        continue
    fi

    # Walk ppid chain
    cur=$pid
    depth=0
    found=false
    while [ "$cur" -gt 1 ] && [ $depth -lt 20 ]; do
        if echo "$pane_pids" | grep -q "^${cur}$"; then
            target=$(/usr/bin/tmux list-panes -a -F '#{pane_pid} #{session_name}:#{window_index}.#{pane_index}' \
                | awk -v p="$cur" '$1==p {print $2}')
            echo "  => pane_pid=$cur target=$target (depth=$depth)"
            found=true
            break
        fi
        ppid=$(awk '/^PPid:/{print $2}' "/proc/${cur}/status" 2>/dev/null || echo "")
        [ -z "$ppid" ] && break
        [ "$ppid" = "$cur" ] && break
        cur=$ppid
        depth=$((depth + 1))
    done

    if [ "$found" = false ]; then
        echo "  => No matching pane_pid found (checked up to depth=$depth)"
    fi
    echo ""
done

echo "=== Done ==="
