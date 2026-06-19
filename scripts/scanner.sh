#!/usr/bin/env bash
# scanner.sh — Dispatch providers, merge NDJSON, filter by scope
# Args: scope (all|current) [session_name]
# Outputs NDJSON lines to stdout
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

SCOPE="${1:-all}"
SESSION_NAME="${2:-}"

# Read provider list from tmux config
PROVIDERS_STR=$(get_opt "@agent-monitor-providers" "claude")
IFS=',' read -ra PROVIDERS <<< "$PROVIDERS_STR"

# Collect NDJSON from all configured providers
ALL_LINES=""
for provider in "${PROVIDERS[@]}"; do
    provider=$(echo "$provider" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -z "$provider" ] && continue

    PROVIDER_SCRIPT="$SCRIPT_DIR/providers/${provider}.sh"
    if [ -x "$PROVIDER_SCRIPT" ]; then
        output=$("$PROVIDER_SCRIPT" 2>/dev/null || true)
        if [ -n "$output" ]; then
            ALL_LINES+="$output"$'\n'
        fi
    fi
done

# If scope is "current", filter by session
if [ "$SCOPE" = "current" ] && [ -n "$SESSION_NAME" ]; then
    FILTERED=""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        target=$(echo "$line" | jq -r '.target // ""' 2>/dev/null || true)
        # target format: session:window.pane — extract session part
        line_session="${target%%:*}"
        if [ "$line_session" = "$SESSION_NAME" ]; then
            FILTERED+="$line"$'\n'
        fi
    done <<< "$ALL_LINES"
    ALL_LINES="$FILTERED"
fi

# Output results
if [ -z "${ALL_LINES:-}" ]; then
    # Empty results: output placeholder
    jq -nc '{pane_id: "__empty__", agent: "", status: "__empty__", cwd: "", started_at: "", uptime: "", summary: "No agents running", target: ""}'
else
    echo -n "$ALL_LINES"
fi

exit 0
