#!/usr/bin/env bash
# helpers.sh — Shared functions for tmux-agent-monitor
set -euo pipefail

TMUX_BIN="${TMUX_BIN:-/usr/bin/tmux}"
# Respect a non-default tmux socket (e.g. TMUX_SOCKET from oh-my-tmux).
# tmuxsocket_args expands to `-S <path>` when TMUX_SOCKET is set, else empty.
if [ -n "${TMUX_SOCKET:-}" ]; then
    TMUX_SOCKET_ARGS=(-S "$TMUX_SOCKET")
else
    TMUX_SOCKET_ARGS=()
fi
# Wrapper that always targets the correct socket.
t() { "$TMUX_BIN" "${TMUX_SOCKET_ARGS[@]}" "$@"; }
SESSIONS_DIR="$HOME/.claude/sessions"

# ── Config ──────────────────────────────────────────────

get_opt() {
    local name="$1" default="$2"
    local val
    val="$(t show-option -gqv "$name" 2>/dev/null)"
    echo "${val:-$default}"
}

require_deps() {
    local missing=()
    for dep in fzf jq perl socat; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "ERROR: tmux-agent-monitor requires: ${missing[*]}" >&2
        echo "Install with: sudo apt install ${missing[*]}" >&2
        exit 1
    fi
}

# ── PID → Pane ──────────────────────────────────────────

pane_id_from_pid() {
    local pid="$1"
    local pane_id
    pane_id=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
        | awk -F= '$1=="TMUX_PANE"{print $2; exit}')
    echo "$pane_id"
}

find_pane_pid() {
    local pid="$1" cur="$pid"
    local pane_pids
    pane_pids="$(t list-panes -a -F '#{pane_pid}' 2>/dev/null)"
    while [ "$cur" -gt 1 ]; do
        if echo "$pane_pids" | grep -q "^${cur}$"; then
            echo "$cur"; return 0
        fi
        local ppid
        ppid=$(awk '/^PPid:/{print $2}' "/proc/$cur/status" 2>/dev/null)
        [ -z "$ppid" ] || [ "$ppid" = "$cur" ] && break
        cur="$ppid"
    done
    return 1
}

pane_id_to_target() {
    local pane_id="$1"
    t list-panes -a -F '#{pane_id} #{session_name}:#{window_index}.#{pane_index}' 2>/dev/null \
        | awk -v id="$pane_id" '$1==id{print $2; exit}'
}

pane_id_to_session() {
    local pane_id="$1"
    t display-message -t "$pane_id" -p '#{session_name}' 2>/dev/null
}

pane_dims() {
    local pane_id="$1"
    t display-message -t "$pane_id" -p '#{pane_width} #{pane_height}' 2>/dev/null
}

# ── Process check ───────────────────────────────────────

is_alive() { kill -0 "$1" 2>/dev/null; }

# ── Text helpers ────────────────────────────────────────

strip_ansi() {
    sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\][0-9]+;[^[:cntrl:]]*(\x07|\x1b\\)//g' \
        | tr -d '\000-\010\013-\037' \
        | sed '/^$/d'
}

format_uptime() {
    local secs="$1"
    if [ "$secs" -lt 0 ]; then secs=0; fi
    local h=$((secs / 3600))
    local m=$(((secs % 3600) / 60))
    local s=$((secs % 60))
    if [ "$h" -gt 0 ]; then
        printf "%dh%dm" "$h" "$m"
    elif [ "$m" -gt 0 ]; then
        printf "%dm%ds" "$m" "$s"
    else
        printf "%ds" "$s"
    fi
}

# ANSI-aware horizontal crop with UTF-8 support.
#   ansi_crop <offset_x> <max_width>  — reads stdin, writes stdout
# offset_x: number of visible chars to skip from the left of each line.
# max_width: number of visible chars to keep after skipping.
# Preserves ANSI SGR sequences; handles multi-byte UTF-8 characters correctly.
ansi_crop() {
    local skip="$1" width="$2"
    perl -CS -e '
        my ($skip, $width) = @ARGV;
        while (<STDIN>) {
            chomp;
            my $visible = 0;
            my $out = "";
            my @sgr = ();          # active SGR stack
            my $emitted_prefix = 0;

            while (length($_)) {
                # ── ANSI CSI sequence ──
                if (s/^(\e\[[0-9;]*[a-zA-Z])//) {
                    my $seq = $1;
                    my $final = substr($seq, -1, 1);
                    my $in_range = ($visible >= $skip && $visible < $skip + $width);
                    if ($final eq "m") {
                        # SGR: track state, include in output if in range
                        my $code = $seq; $code =~ s/^\e\[//; $code =~ s/m$//;
                        if ($code eq "0" || $code eq "") { @sgr = (); }
                        else { push @sgr, $seq; }
                        $out .= $seq if $in_range;
                    }
                    # Non-SGR CSI — silently dropped (no meaning in snapshot)
                    next;
                }
                # ── UTF-8 character (may be multi-byte) ──
                s/^(\X)//;
                my $c = $1;
                $visible++;
                next if $visible <= $skip;
                last if $visible > $skip + $width;

                # First visible char: re-emit SGR state
                if (!$emitted_prefix && $skip > 0 && @sgr) {
                    $out .= "\e[0m" . join("", @sgr);
                    $emitted_prefix = 1;
                }
                $out .= $c;
            }
            # Always close with SGR reset
            $out .= "\e[0m" if length($out);
            print "$out\n";
        }
    ' "$skip" "$width"
}

# ── State directory ─────────────────────────────────────

STATE_DIR="${STATE_DIR:-/tmp/agent-monitor-$$}"
ensure_state_dir() { mkdir -p "$STATE_DIR" 2>/dev/null; }
export STATE_DIR

# ── NDJSON → fzf display ───────────────────────────────

format_stream() {
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local pane_id st agent cwd uptime summary target
        pane_id=$(echo "$line" | jq -r '.pane_id // "?"')
        st=$(echo "$line" | jq -r '.status // "?"')
        agent=$(echo "$line" | jq -r '.agent // "?"')
        cwd=$(echo "$line" | jq -r '.cwd // "?"')
        uptime=$(echo "$line" | jq -r '.uptime // "?"')
        summary=$(echo "$line" | jq -r '.summary // ""')
        target=$(echo "$line" | jq -r '.target // ""')

        # Handle empty placeholder line
        if [ "$st" = "__empty__" ]; then
            printf "__empty__\t\033[2m  %s\033[0m\t%s\n" "$summary" "$line"
            continue
        fi

        local color
        case "$st" in
            busy)      color="33" ;;  # yellow
            idle)      color="32" ;;  # green
            waiting*)  color="35" ;;  # magenta
            *)         color="37" ;;  # white
        esac

        local cwd_disp="$cwd"
        if [ "${#cwd_disp}" -gt 35 ]; then
            cwd_disp="…${cwd_disp: -34}"
        fi

        local st_col agent_col cwd_col uptime_col
        st_col=$(printf '%-15s' "$st")
        agent_col=$(printf '%-8s' "$agent")
        cwd_col=$(printf '%-35s' "$cwd_disp")
        uptime_col=$(printf '%8s' "$uptime")

        # Output: pane_id \t display \t json_line
        printf "%s\t" "$pane_id"
        printf "\033[1;${color}m%s\033[0m" "$st_col"
        printf "%s" "$agent_col"
        printf "%s" "$cwd_col"
        printf "\033[2m%s\033[0m" "$uptime_col"
        printf " %s" "$summary"
        printf "\t%s\n" "$line"
    done
}
