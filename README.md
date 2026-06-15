# tmux-agent-monitor

Monitor Claude AI agents running across tmux panes — real-time status, live preview, one-key jump to any agent pane. Cross-session support.

## Requirements

- tmux >= 3.0
- fzf >= 0.48 (for `--listen` HTTP API)
- jq

```bash
sudo apt install fzf jq
```

## Install (TPM)

```tmux
set -g @plugin 'ipyffor/tmux-agent-manage'
```

Press `prefix + I` to install.

## Configuration

Put in `~/.tmux.conf`, **after** the TPM `run` line:

```tmux
set -g @agent-monitor-processes "claude"       # process names, comma-separated
set -g @agent-monitor-refresh-interval "2"     # scan interval (seconds)
set -g @agent-monitor-summary-lines "1"        # summary: last N lines of output
set -g @agent-monitor-preview-ratio "80"       # preview height % (fzf down position)
set -g @agent-monitor-fzf-args ""              # extra fzf flags
```

## Key Bindings

The plugin does **not** set default keys. Add your own:

```tmux
bind-key g run-shell "~/.tmux/plugins/tmux-agent-manage/scripts/monitor.sh all"
bind-key G run-shell "~/.tmux/plugins/tmux-agent-manage/scripts/monitor.sh current"
```

## Usage

1. Have Claude CLI running in one or more tmux panes
2. Press your bound key → monitor opens in a new tmux window
3. **List** shows: STATUS | AGENT | CWD | UPTIME | SUMMARY
4. **↑↓** move cursor, preview updates below
5. **Enter** switches to the selected agent's pane (cross-session)
6. **Esc** closes the monitor
7. **Ctrl-R** manually refreshes the list
8. **Shift+↑↓** scrolls the preview

## Status

| Color | Status | Meaning |
|-------|--------|---------|
| yellow | busy | Claude is working |
| green | idle | Waiting for user input |
| magenta | waiting | Blocked on permission/confirmation |

## How It Works

1. Scans `~/.claude/sessions/<pid>.json` for live Claude sessions
2. Maps Claude PID → ancestor tmux pane via PPid chain
3. Reads `status` field from session file — no terminal output parsing needed
4. `capture-pane` for live preview
5. Pane inactive → scanning stops (zero resource)

## TODO

### Preview: real tmux pane instead of fzf built-in

**Problem:** The current preview uses fzf's `--preview` window (fixed viewport). It cannot perfectly display all target pane layouts:
- Wide/tall splits may require horizontal/vertical scrolling
- Wrapped lines can break terminal formatting
- Preview size is a percentage of fzf's window, not the target pane's actual dimensions

**Planned fix:** Replace fzf `--preview` with a real tmux split pane that:
1. Splits the monitor window into `[fzf list | live preview pane]`
2. Resizes the preview pane to match the target pane's width and height on selection
3. Shows `capture-pane` output without any transformation (true 1:1 rendering)

**Status:** Prototyped but caused tmux instability (`kill-window` / `send-keys` / pane lifecycle race conditions). Needs a clean, robust implementation of the two-pane lifecycle.
