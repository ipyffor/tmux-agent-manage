#!/usr/bin/env bash
# monitor.sh — Main entry point: creates fzf+preview monitor window
# Args: scope (all|current)
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

# ── Re-exec in new window if not in a TTY ──────────────

if [ ! -t 0 ] || [ ! -t 1 ]; then
    exec "$TMUX_BIN" "${TMUX_SOCKET_ARGS[@]}" new-window -n "agent-monitor" "$(CDPATH= cd "$(dirname "$0")" && pwd)/monitor.sh" "$@"
fi

require_deps
ensure_state_dir

# ── Args ────────────────────────────────────────────────

SCOPE="${1:-all}"
SESSION_NAME=""
if [ "$SCOPE" = "current" ]; then
    SESSION_NAME=$(t display-message -p '#{session_name}' 2>/dev/null || echo "")
fi

# ── Config ──────────────────────────────────────────────

INTERVAL=$(get_opt "@agent-monitor-refresh-interval" "2")
PREVIEW_POS=$(get_opt "@agent-monitor-preview-position" "down")
PREVIEW_RATIO=$(get_opt "@agent-monitor-preview-ratio" "50")
SCROLL_STEP=$(get_opt "@agent-monitor-scroll-step" "1")
FZF_ARGS=$(get_opt "@agent-monitor-fzf-args" "")

MONITOR_PANE="${TMUX_PANE:-}"
if [ -z "$MONITOR_PANE" ]; then
    echo "ERROR: monitor.sh must run inside a tmux pane" >&2
    exit 1
fi
MONITOR_WINDOW=$(t display-message -p '#{window_id}' 2>/dev/null || echo "")

# ── State files ─────────────────────────────────────────

echo "0" > "$STATE_DIR/offset_x"
echo "0" > "$STATE_DIR/offset_y"
echo ""  > "$STATE_DIR/current"

# ── Split window ────────────────────────────────────────
# Default: vertical split (top=fzf, bottom=preview)

if [ "$PREVIEW_POS" = "right" ]; then
    SPLIT_FLAG="-h"
else
    SPLIT_FLAG="-v"
fi

# -PF captures the new pane_id created by split-window (tmux 3.2+)
# Pass TMUX_SOCKET into the preview pane so its `t` wrapper hits the same server.
SPLIT_ENV=(-e "STATE_DIR=$STATE_DIR" -e "TMUX_BIN=$TMUX_BIN")
[ -n "${TMUX_SOCKET:-}" ] && SPLIT_ENV+=(-e "TMUX_SOCKET=$TMUX_SOCKET")
PREVIEW_PANE=$(t split-window $SPLIT_FLAG -p "$PREVIEW_RATIO" -PF '#{pane_id}' \
    "${SPLIT_ENV[@]}" \
    "exec $SCRIPT_DIR/preview.sh" 2>/dev/null || echo "")

# ── Refresh feed script ─────────────────────────────────

REFRESH_SCRIPT="$SCRIPT_DIR/refresh-feed.sh"

# Return focus to fzf pane BEFORE the initial data load.
# split-window gave focus to the preview pane, so the monitor pane is currently
# inactive — refresh-feed.sh's visibility guard would see pane_active=0 and return
# empty data, leaving STATE_DIR/current blank and the preview stuck on the
# "select an agent" placeholder. Restoring focus first keeps the guard happy.
t select-pane -t "$MONITOR_PANE" 2>/dev/null || true

# Initial data
INITIAL_DATA=$("$REFRESH_SCRIPT" "$SCOPE" "$SESSION_NAME" "$MONITOR_PANE" 2>/dev/null || true)

# Pre-fill preview with first real agent so it's not blank on startup
FIRST_PANE_ID=$(echo "$INITIAL_DATA" | grep -v '__empty__' | head -1 | cut -f1 2>/dev/null || echo "")
if [ -n "$FIRST_PANE_ID" ] && [ "$FIRST_PANE_ID" != "__empty__" ]; then
    echo "$FIRST_PANE_ID" > "$STATE_DIR/current"
fi

# ── Periodic refresh via fzf --listen Unix socket ───────

FZF_SOCK="$STATE_DIR/fzf.sock"

# Start background reload loop (sends reload actions via Unix socket HTTP POST)
(
    while true; do
        sleep "$INTERVAL"
        active=$(t display-message -t "$MONITOR_PANE" -p '#{pane_active}' 2>/dev/null || echo "0")
        if [ "$active" = "1" ]; then
            reload_cmd="reload($REFRESH_SCRIPT '$SCOPE' '${SESSION_NAME//\'/\'\\\'\'}' '${MONITOR_PANE//\'/\'\\\'\'}')"
            curl -s --unix-socket "$FZF_SOCK" http -d "$reload_cmd" >/dev/null 2>&1 || true
        fi
    done
) &
RELOAD_LOOP_PID=$!

# ── Cleanup ─────────────────────────────────────────────

cleanup() {
    # Kill reload loop
    [ -n "${RELOAD_LOOP_PID:-}" ] && kill "$RELOAD_LOOP_PID" 2>/dev/null || true
    # Kill monitor window by its saved ID (not current — switch-client may have moved us)
    if [ -n "${MONITOR_WINDOW:-}" ]; then
        t kill-window -t "$MONITOR_WINDOW" 2>/dev/null || true
    fi
    # Clean up state directory
    rm -rf "$STATE_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── Launch fzf ──────────────────────────────────────────

fzf \
    --listen="$FZF_SOCK" \
    --delimiter=$'\t' \
    --with-nth=2 \
    --id-nth=1 \
    --track \
    --header='STATUS          AGENT    CWD                                UPTIME   SUMMARY' \
    --bind "focus:execute-silent(echo {1} > $STATE_DIR/current; echo 0 > $STATE_DIR/offset_x; echo 0 > $STATE_DIR/offset_y)" \
    --bind "load:execute-silent([ -s $STATE_DIR/current ] || echo {1} > $STATE_DIR/current)+reload(sleep 0.5; $REFRESH_SCRIPT $SCOPE '${SESSION_NAME//\'/\'\\\'\'}' '${MONITOR_PANE//\'/\'\\\'\'}')" \
    --bind "ctrl-r:reload($REFRESH_SCRIPT $SCOPE '${SESSION_NAME//\'/\'\\\'\'}' '${MONITOR_PANE//\'/\'\\\'\'}')" \
    --bind "shift-up:execute-silent(y=\$(cat $STATE_DIR/offset_y 2>/dev/null || echo 0); echo \$((y + ${SCROLL_STEP})) > $STATE_DIR/offset_y)" \
    --bind "shift-down:execute-silent(y=\$(cat $STATE_DIR/offset_y 2>/dev/null || echo 0); if [ \$y -ge ${SCROLL_STEP} ]; then echo \$((y - ${SCROLL_STEP})) > $STATE_DIR/offset_y; else echo 0 > $STATE_DIR/offset_y; fi)" \
    --bind "shift-right:execute-silent(x=\$(cat $STATE_DIR/offset_x 2>/dev/null || echo 0); echo \$((x + ${SCROLL_STEP})) > $STATE_DIR/offset_x)" \
    --bind "shift-left:execute-silent(x=\$(cat $STATE_DIR/offset_x 2>/dev/null || echo 0); if [ \$x -ge ${SCROLL_STEP} ]; then echo \$((x - ${SCROLL_STEP})) > $STATE_DIR/offset_x; else echo 0 > $STATE_DIR/offset_x; fi)" \
    --bind "enter:execute($SCRIPT_DIR/switch.sh {1})+abort" \
    --bind "esc:abort" \
    --layout=reverse \
    --ansi \
    $FZF_ARGS \
    <<< "$INITIAL_DATA"

exit 0
