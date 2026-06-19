#!/usr/bin/env bash
# generic.sh — Generic agent provider (stub)
# Reserved for future agent discovery: Codex, Copilot CLI, Aider, etc.
# When implemented, this script will:
#   1. Scan process tree for known agent process names (configurable via
#      @agent-monitor-processes or similar tmux option)
#   2. Map PID → tmux pane via pane_id_from_pid / PPid fallback
#   3. Infer status from process activity (CPU usage, output rate, etc.)
#   4. Output NDJSON on stdout (same schema as claude.sh)
#
# For now: output nothing.
set -euo pipefail
exit 0
