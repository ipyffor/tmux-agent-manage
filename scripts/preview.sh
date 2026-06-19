#!/usr/bin/env bash
# preview.sh — Persistent loop: reads target pane_id, renders capture-pane output
# Runs in the preview split pane. Never exits until killed by monitor.sh trap.
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

ensure_state_dir

PREVIEW_PANE="${TMUX_PANE:-}"
SCROLL_STEP=$(get_opt "@agent-monitor-scroll-step" "1")

# ── Clamp offset helper (read-only — does NOT write state files) ──
# Only fzf bindings write offsets; preview loop only clamps locally to avoid
# write/write races between concurrent fzf bindings and the preview loop.

clamp_offset() {
    local offset="${1//[^0-9]/}" max="${2//[^0-9]/}"
    offset="${offset:-0}"; max="${max:-0}"
    if [ "$offset" -gt "$max" ]; then
        echo "$max"
    elif [ "$offset" -lt 0 ]; then
        echo "0"
    else
        echo "$offset"
    fi
}

# Sanitize a value to a non-negative integer (guards against race-read garbage)
to_int() {
    local v="${1//[^0-9]/}"
    echo "${v:-0}"
}

# ── Main loop ────────────────────────────────────────────

while true; do
    target=$(cat "$STATE_DIR/current" 2>/dev/null || true)

    if [ -z "$target" ] || [ "$target" = "__empty__" ]; then
        printf '\033[H\033[J\033[2m  select an agent to preview\033[0m\n'
        sleep 0.3
        continue
    fi

    # Read scroll offsets (sanitize — state files may be mid-write)
    offset_x=$(to_int "$(cat "$STATE_DIR/offset_x" 2>/dev/null || echo 0)")
    offset_y=$(to_int "$(cat "$STATE_DIR/offset_y" 2>/dev/null || echo 0)")

    # Verify target still exists
    if ! t display-message -t "$target" -p '#{pane_id}' &>/dev/null; then
        printf '\033[H\033[2m  pane gone\033[0m\n'
        sleep 0.3
        continue
    fi

    # ── Dimensions ───────────────────────────────────────

    t_dims=$(pane_dims "$target" 2>/dev/null || echo "0 0")
    t_w=$(to_int "${t_dims% *}")
    t_h=$(to_int "${t_dims##* }")

    if [ -z "$PREVIEW_PANE" ]; then
        PREVIEW_PANE=$(t display-message -p '#{pane_id}' 2>/dev/null || echo "")
    fi

    p_dims=$(pane_dims "$PREVIEW_PANE" 2>/dev/null || echo "0 0")
    p_w=$(to_int "${p_dims% *}")
    p_h=$(to_int "${p_dims##* }")

    [ "$t_w" -le 0 ] && t_w=1
    [ "$t_h" -le 0 ] && t_h=1
    [ "$p_w" -le 0 ] && p_w=80
    [ "$p_h" -le 0 ] && p_h=10

    # ── Compute max offsets ──────────────────────────────

    max_x=$((t_w - p_w))
    [ "$max_x" -lt 0 ] && max_x=0

    max_y=$((t_h - p_h))
    [ "$max_y" -lt 0 ] && max_y=0

    # Re-clamp offsets each cycle (target may have resized)
    offset_x=$(clamp_offset "$offset_x" "$max_x")
    offset_y=$(clamp_offset "$offset_y" "$max_y")

    # ── Conditional resize (only shrink, never grow) ─────

    if [ "$t_w" -le "$p_w" ] && [ "$t_h" -le "$p_h" ]; then
        t resize-pane -t "$PREVIEW_PANE" -x "$t_w" -y "$t_h" 2>/dev/null || true
        # Re-read after resize (tmux may round)
        p_dims=$(pane_dims "$PREVIEW_PANE" 2>/dev/null || echo "$t_w $t_h")
        p_w=${p_dims% *}
        p_h=${p_dims##* }
        [ "$p_w" -le 0 ] && p_w="$t_w"
        [ "$p_h" -le 0 ] && p_h="$t_h"
        # Re-clamp after resize (preview may have changed size)
        max_x=$((t_w - p_w)); [ "$max_x" -lt 0 ] && max_x=0
        max_y=$((t_h - p_h)); [ "$max_y" -lt 0 ] && max_y=0
        offset_x=$(clamp_offset "$offset_x" "$max_x")
        offset_y=$(clamp_offset "$offset_y" "$max_y")
    fi

    # ── Capture visible area, apply vertical offset ─────
    # Reserve 1 line for status bar
    content_h=$((p_h - 1))
    [ "$content_h" -le 0 ] && content_h=1

    content=$(t capture-pane -p -e -t "$target" 2>/dev/null || true)
    if [ "$offset_y" -gt 0 ]; then
        content=$(echo "$content" | tail -n $((content_h + offset_y)) 2>/dev/null | head -n "$content_h" 2>/dev/null || true)
    else
        content=$(echo "$content" | tail -n "$content_h" 2>/dev/null || true)
    fi

    # ── Apply horizontal crop (ANSI-aware) ──────────────

    cropped=$(echo "$content" | ansi_crop "$offset_x" "$p_w" 2>/dev/null || true)

    # ── Status bar ──────────────────────────────────────

    target_info="${t_w}×${t_h}"
    scroll_v="" ; scroll_h=""
    if [ "$max_y" -gt 0 ]; then
        pos_y=$((max_y - offset_y + 1))
        total_y=$((max_y + 1))
        scroll_v=" ↕${pos_y}/${total_y}"
    fi
    if [ "$max_x" -gt 0 ]; then
        pos_x=$((offset_x + 1))
        total_x=$((max_x + 1))
        scroll_h=" ↔${pos_x}/${total_x}"
    fi
    if [ -z "$scroll_v$scroll_h" ]; then
        status_line="$(printf '\033[2m%s  (1:1)\033[0m' "$target_info")"
    else
        status_line="$(printf '\033[2m%s\033[0m\033[33m%s%s\033[0m' "$target_info" "$scroll_v" "$scroll_h")"
    fi

    # ── Display ──────────────────────────────────────────
    # Use ANSI cursor positioning instead of clear (faster, less flicker)
    printf '\033[H\033[J'                    # home + clear
    echo -n "$cropped"                       # content (content_h lines)
    printf '\033[%d;1H' "$p_h"              # cursor to bottom row
    printf '%s' "$status_line"              # status bar pinned to bottom

    sleep 0.1
done
