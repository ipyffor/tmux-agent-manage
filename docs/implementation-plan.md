# Plan: tmux-agent-monitor

**Source**: `docs/architecture.md`
**Complexity**: Medium

## Summary

构建一个 tmux 插件（Bash + fzf），监控所有 tmux pane 中运行的 Claude agent，提供实时状态列表、fzf 上下分屏预览、回车跨会话切换、面板不可见时零资源占用。先实现 Claude，Codex 等其他 agent 留接口占位后续加入。

## Patterns to Mirror

| Category | Pattern |
|---|---|
| 命名 | 入口 `name.tmux`，脚本在 `scripts/`，函数名 `snake_case` |
| 错误处理 | `set -euo pipefail`；缺依赖 `echo "ERROR: ..." >&2 && exit 1` |
| tmux option 读取 | `tmux show-option -gqv @plugin-option` |
| 脚本间通信 | 管道 + NDJSON，每行一个完整 JSON 对象 |

## Files to Create

| File | Action | Why |
|---|---|---|
| `agent-monitor.tmux` | CREATE | TPM 入口，设默认配置，不绑键 |
| `scripts/helpers.sh` | CREATE | 共享函数：读配置、依赖检查、PID→pane 映射 |
| `scripts/scanner.sh` | CREATE | 扫描 claude sessions，输出 NDJSON |
| `scripts/preview.sh` | CREATE | capture-pane 渲染目标 pane 实时画面 |
| `scripts/switch.sh` | CREATE | switch-client 跨会话切换 |
| `scripts/monitor.sh` | CREATE | 主入口：fzf 面板 + 轮询管理 + hook 注册 |
| `README.md` | CREATE | 安装、配置、快捷键绑定示例 |

## NDJSON 数据格式

```json
{"status":"busy","agent":"claude","cwd":"/home/user/project","target":"work:0.1","uptime":342,"summary":"analyzing code..."}
```

字段说明：
- `status`：`busy` | `idle` | `waiting`（来自 `~/.claude/sessions/<pid>.json`）
- `agent`：进程名
- `cwd`：项目路径（session 文件 cwd > pane_current_path）
- `target`：`session:window.pane` 坐标，供 switch/preview 使用
- `uptime`：运行秒数（now - startedAt）
- `summary`：capture-pane 末行过滤后的纯文本

## Tasks

### Phase 0: 脚手架 + 依赖检查

- **Action**: 建目录结构；`agent-monitor.tmux` 设六个 `@agent-monitor-*` 默认值；`helpers.sh` 实现 `get_opt()` 和 `require_deps()`；所有脚本加 shebang + `set -euo pipefail`
- **默认配置**:
  ```
  @agent-monitor-processes        "claude"
  @agent-monitor-refresh-interval "2"
  @agent-monitor-summary-lines    "1"
  @agent-monitor-preview-ratio    "60"
  @agent-monitor-fzf-args         ""
  @agent-monitor-scope            "all"
  ```
- **Validate**: `tmux source agent-monitor.tmux && tmux show-option -gv @agent-monitor-processes` 输出 `claude`；临时去掉 fzf 跑 monitor.sh 应报友好错误

### Phase 1: PID→pane 映射验证（先验证再实现）⚠️

- **Action**: 写独立验证脚本，从 `~/.claude/sessions/<pid>.json` 取 pid，沿 `/proc/<pid>/status` PPid 链向上，匹配 `tmux list-panes -a` 的 `pane_pid`
- **验证脚本**:
  ```bash
  pid=$(ls ~/.claude/sessions/*.json | head -1 | xargs jq -r .pid)
  cur=$pid
  while [ "$cur" -gt 1 ]; do
    ppid=$(awk '/^PPid/{print $2}' /proc/$cur/status 2>/dev/null) || break
    if tmux list-panes -a -F '#{pane_pid}' | grep -q "^$ppid$"; then
      echo "Found pane_pid: $ppid"
      tmux list-panes -a -F '#{pane_pid} #{session_name}:#{window_index}.#{pane_index}' | grep "^$ppid"
      break
    fi
    cur=$ppid
  done
  ```
- **Validate**: 真实开一个 claude，跑验证脚本，输出正确的 `session:window.pane`；确认 nvim 嵌套场景也能正确找到 pane

### Phase 2: scanner.sh

- **Action**:
  1. 列 `~/.claude/sessions/*.json`，jq 解析 pid/status/cwd/startedAt/waitingFor
  2. `kill -0 <pid>` stale 校验，死进程跳过
  3. PPid 链向上找祖先 pane（Phase 1 验证过的逻辑）
  4. scope 参数过滤（current 时按传入 session_name 过滤）
  5. `capture-pane -p -t <pane>` 取末尾行，过滤控制字符和空行做 summary
  6. 输出 NDJSON；无结果时输出空（monitor 负责显示占位）
- **Validate**:
  ```bash
  bash scripts/scanner.sh all
  # 应输出含正确 target 坐标的 JSON 行
  # 杀掉 claude 后再跑，输出空
  ```

### Phase 3: switch.sh + preview.sh

- **switch.sh Action**: 解析 target `session:window.pane`，依次执行 `switch-client`、`select-window`、`select-pane`
- **preview.sh Action**: 从 fzf 传入行解析 target 字段，`tmux capture-pane -ep -t <target>` 输出
- **Validate**:
  ```bash
  bash scripts/switch.sh "work:0.1"
  bash scripts/preview.sh '{"target":"work:0.1",...}'
  ```

### Phase 4: fzf reload 验证 ⚠️ + monitor.sh

- **先验证 fzf reload 光标保持**:
  ```bash
  seq 100 | fzf \
    --bind 'load:reload(seq $((RANDOM % 100 + 50)))' \
    --preview 'echo item: {}'
  # 移到中间，等 reload，确认光标不跳回顶部
  ```
- **monitor.sh Action**:
  1. 接 `scope` 参数；current 时捕获 `#{session_name}`
  2. fzf：`--ansi --layout=reverse --preview 'scripts/preview.sh {}'`
  3. `--preview-window down:<ratio>%:wrap`
  4. 定时 reload：后台 loop sleep + fzf `--bind 'load:reload(...)'`
  5. 空列表时显示 "No agents running"（不可选中占位行）
  6. enter binding：jq 提取 target，调 switch.sh
- **Validate**: `bash scripts/monitor.sh all` 列表正确；预览跟光标；回车切换成功；reload 后光标不乱跳

### Phase 5: 生命周期 hook — 可见性开关 ⚠️

- **先确认可用 hook**: `tmux list-hooks -g | grep -E 'pane|window|client'`
- **实现方案**（flag 文件控制轮询）:
  1. monitor.sh 启动时写 flag `/tmp/agent-monitor-<pane_id>.active`
  2. 注册 hook 在 `client-session-changed` / `pane-focus-out` 时检查面板可见性，更新 flag
  3. 后台轮询循环每次检查 flag，不活跃则 skip scan
  4. monitor.sh 退出时 trap EXIT 清理 flag + hook
- **降级方案**: 若 hook 判断不可靠 → 退为「fzf 进程存活即轮询，fzf 退出即停」
- **Validate**:
  ```bash
  # 切走面板 → ps | grep scanner 为空
  # 切回面板 → 扫描恢复
  # 关闭面板 → /tmp/agent-monitor-*.active 已清理
  ```

### Phase 6: README + 端到端

- **Action**: 写 README（安装、配置变量表、快捷键示例、依赖说明 tmux>=3.0/fzf/jq）；端到端真实工作流走一遍
- **绑定示例**:
  ```tmux
  bind-key g run-shell "~/.tmux/plugins/tmux-agent-monitor/scripts/monitor.sh all"
  bind-key G run-shell "~/.tmux/plugins/tmux-agent-monitor/scripts/monitor.sh current"
  ```

## Validation

```bash
# Phase 0
tmux source agent-monitor.tmux
tmux show-option -gv @agent-monitor-processes  # => claude

# Phase 2
bash scripts/scanner.sh all  # => NDJSON with correct target

# Phase 3
bash scripts/switch.sh "session:0.1"  # => jumps to pane

# Phase 4
bash scripts/monitor.sh all  # => full interactive panel
```

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| PID→pane ppid 链在 nvim 嵌套下断链 | Medium | Phase 1 先验证；断链则 fallback 到 `pane_current_command` 匹配 |
| fzf reload 重置光标位置 | Medium | Phase 4 先验证，按 fzf 版本调参数 |
| tmux hook 判断可见性不可靠 | High | 明确降级方案：fzf 存活即轮询 |
| capture-pane summary 含 TUI 边框字符 | Medium | 过滤非 printable ASCII + 空行 |

## Acceptance

- [ ] Phase 0: TPM 加载无报错，默认配置正确
- [ ] Phase 1: PID→pane 映射在 nvim 嵌套下验证通过
- [ ] Phase 2: scanner 输出正确 NDJSON，stale 校验有效
- [ ] Phase 3: switch/preview 单独可用
- [ ] Phase 4: fzf 面板完整可交互，reload 不乱跳
- [ ] Phase 5: 可见性开关有效（或降级方案落地）
- [ ] Phase 6: README 完整，端到端验证通过
