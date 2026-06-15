# tmux-agent-monitor 架构文档

日期：2026-06-14

## 用户工作流

- 一个 Neovim 实例对应一个 tmux pane 或窗口，打开一个工程
- 在 Neovim 悬浮窗开启 Claude CLI 终端运行 agent
- 多个 tmux session（每个项目一个 session）
- 想知道各个 tmux 下的 Neovim 中 Claude/Codex agent 的进度
- 需要能展示进度 + 切换到 agent 所在的 tmux pane（跨会话切换）

## 核心需求汇总

| 维度 | 决定 |
|------|------|
| 监控对象 | 终端中运行的 Claude、Codex 等 AI agent，不绑定特定 Neovim 插件 |
| 检测方式 | 通过 tmux 接口获取所有 pane 的进程，匹配进程名 |
| Agent 识别 | 内置默认列表 + 用户可在配置中扩展 |
| 进度提取 | 读 Claude session 状态文件 `~/.claude/sessions/<pid>.json` 获取 `status` 字段（busy/idle/waiting） |
| 完成判定 | 进程退出则移除；agent 回答完毕等待用户输入/确认时视为完成/等待状态 |
| 监控范围 | 可配置：当前 session / 所有 session，不同快捷键绑定不同范围 |
| 面板形式 | 普通 tmux pane，和其他 pane 一样管理；面板不可见时不扫描刷新 |
| 面板内容 | 列表视图：agent名 | 项目路径 | 运行时长 | 状态（完成态最显眼） |
| 预览 | 光标停住后延迟弹出浮窗，显示实时 pane 画面 + 摘要；移动光标则关闭预览 |
| 切换 | 基于 tmux：该切会话切会话，该切窗口切窗口，焦点落在目标 pane |
| 快捷键 | 插件不默认绑定，由用户自己绑定 |
| 交互 | 使用 fzf 做列表和交互 |
| 安装 | TPM (Tmux Plugin Manager) |
| 配置 | tmux 变量 (@agent-monitor-*) |
| 架构 | 方案 A：纯 Bash + fzf |
| 刷新策略 | 混合：tmux hooks 响应事件 + 轮询刷新摘要；仅面板可见时扫描 |

## 调研结果

### 调研 1：状态检测 — 不需要解析终端输出

**关键发现：Claude CLI 会持续写入会话状态文件 `~/.claude/sessions/<pid>.json`：**

```json
{
  "pid": 108341,
  "sessionId": "f3d6b726-...",
  "cwd": "/home/gotpl/project",
  "status": "busy",
  "waitingFor": null,
  "startedAt": 1781451426701,
  "version": "2.1.153",
  "kind": "interactive"
}
```

**`status` 字段含义：**

| status | 含义 | 对应阶段 |
|--------|------|----------|
| `"busy"` | 正在工作 | thinking / executing / answering |
| `"idle"` | 空闲，等待输入 | 刚启动还没提问 |
| `"waiting"` + `"waitingFor"` | 等人操作 | permission prompt 等 |

**这意味着插件完全不需要解析终端输出的关键词。** 找到 pane 里跑的 Claude 进程 PID → 读 `~/.claude/sessions/<pid>.json` → 直接拿到状态和项目路径（`cwd` 字段）。

**Codex 等其他 agent：** 需要后续调研各自的状态文件机制。对于没有状态文件的 agent，降级方案：
- 进程存在 + 有最近输出 → "busy"
- 进程存在 + 长时间无新输出 → "idle/waiting"
- 进程不存在 → 条目移除

### 调研 2：项目路径获取

**推荐方法（按优先级）：**

1. **Claude session 文件的 `cwd` 字段** — 如果有，直接取，最准
2. **`tmux display -t <pane> -p '#{pane_current_path}'`** — tmux 主动维护，等价于 `/proc/<pane_pid>/cwd`，实时跟踪 `cd`，当 Neovim 在前台时返回项目根目录
3. **`#{pane_path}`（OSC 7）** — 需要 URI 解析，取决于终端应用支持
4. **`#{pane_start_path}`** — 最后兜底，pane 创建时冻结，不跟踪 `cd`

**实际使用：** 优取 Claude session 的 `cwd`，否则用 `pane_current_path`。

## 数据流

```
┌─────────────┐    pane列表     ┌─────────────┐
│  scanner.sh │ ──────────────> │ monitor.sh   │
│             │   JSON Lines    │  (fzf 面板)  │
│ 遍历pane     │                │              │
│ 匹配进程     │                │ 列表显示      │
│ 读session    │                │ 选中预览      │
│ 文件取状态   │                │ 确认切换      │
└─────────────┘                └──────┬───────┘
       ↑                              │
       │ 定时轮询(仅面板可见时)         │ 确认切换
       │                              │
  ┌────┴────────┐              ┌──────┴───────┐
  │ tmux hooks  │              │  tmux        │
  │ pane-created│              │  switch-client│
  │ pane-exited │              │              │
  └─────────────┘              └──────────────┘
```

## 详细问答记录

### Q1: Claude/Codex 以什么方式运行？
无论什么方式启动的 claude 或 codex，都是在终端运行的。不绑定特定 Neovim 插件。

### Q2: 进度指什么？
摘要显示任务状态（类似 idle/thinking/executing/done）、实时显示。选中时可预览 Claude 画面，确认后可切换。

### Q3: 如何发现 agent 进程？
通过 tmux 接口获取在 tmux 中打开的进程，查询所在 pane，然后切换。

### Q4: 监控界面形式？
设定就是一个 pane，因此浮窗或单独窗口都可以，用户自己决定。

### Q5: 跨会话切换需求？
面板实时显示所有进程的进度摘要，光标移动到对应进程时出现预览窗口，按回车或其他快捷键确认切换。

### Q6: 插件形式？
Bash + fzf 的 tmux 插件。

### Q7: 如何提取进度？
~~关键词匹配阶段~~ → 已更新：读 Claude session 状态文件 `~/.claude/sessions/<pid>.json` 的 `status` 字段。

### Q8: 除了 Claude 和 Codex 还需要监控哪些？
内置默认常见 agent + 用户可在配置中扩展。

### Q9: 监控范围？
可配置：默认所有 session，可配置为只监控当前 session 或指定 session 列表。不同快捷键绑定不同范围。

### Q10: 预览窗口显示什么？
实时显示目标 pane 的画面（类似 tmux capture-pane 持续刷新），最简单的方式。

### Q11: 列表视图显示哪些信息？
agent名 | 项目路径 | 运行时长 | 状态（完成态最显眼）。

### Q12: 如何判断 agent 完成？
进程不存在就移除。任务结束暂定为 agent 回答完毕，需要用户提供新的输入或 agent 给出选项需要确认等需要人干预时视为完成/等待。

### Q13: 刷新频率？
混合模式：事件驱动 + 轮询兜底。只有打开面板时才扫描，退出面板或在界面看不到则不扫描刷新（包括切换到其他窗口、其他会话等）。

### Q14: 预览窗口位置和大小？
浮动覆盖，作为独立 popup。比面板稍小。光标停住超过阈值才显示预览，移动光标则关闭。浮窗中找位置显示当前选中项的摘要。

### Q15: 退出面板后行为？
面板就是普通 tmux pane，和其他 pane 一模一样处理。

### Q16: 确认切换行为？
基于 tmux：该切会话切会话，会话内部基于 window 切换，焦点放到目标 pane。

### Q17: 状态关键词匹配规则？
已解决。Claude 写 session 状态文件，不需要关键词匹配。Codex 等后续调研，降级方案用进程活跃度判断。

### Q18: 快捷键？
插件不默认绑定，由用户绑定。

### Q19: 进程名？
实际进程名叫 `claude`。

### Q20: 安装方式？
TPM (Tmux Plugin Manager)。

### Q21: 项目路径获取？
已解决。优取 Claude session 的 `cwd`，fallback 到 `tmux pane_current_path`。

### Q22: 配置文件格式？
tmux 变量 (@agent-monitor-*)，标准 tmux 插件风格。
