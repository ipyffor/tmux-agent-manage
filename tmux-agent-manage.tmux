# tmux-agent-monitor — TPM entry point
# Does NOT bind any keys. Place user overrides after the TPM run line in tmux.conf.

set -g @agent-monitor-providers "claude"
set -g @agent-monitor-refresh-interval "2"
set -g @agent-monitor-summary-lines "1"
set -g @agent-monitor-preview-position "down"
set -g @agent-monitor-preview-ratio "50"
set -g @agent-monitor-scroll-step "1"
set -g @agent-monitor-fzf-args ""
set -g @agent-monitor-scope "all"
