# tmux-agent-monitor 架构文档

日期：2026-06-14

## 1. 目标与用户工作流

- 一个 Neovim 实例对应一个 tmux pane 或窗口，打开一个工程
- 在 Neovim 悬浮窗开启 Claude CLI 终端运行 agent
- 多个 tmux session（每个项目一个 session）
- 需求：在一个面板里实时看到所有 tmux 下 Claude agent 的进度，并能选中切换到 agent 所在的 tmux pane（跨会话切换）

**当前范围：先实现 Claude，Codex 等其他 agent 留接口占位后续加入。**

## 2. 核心决策汇总

| 维度 | 决定 |
|------|------|
| 监控对象 | 终端中运行的 Claude（进程名 `claude`）；Codex 等后续扩展，配置可加 |
| Agent 识别 | 内置默认列表（claude）+ 用户可在配置中扩展进程名 |
| 进度来源 | 读 Claude session 状态文件 `~/.claude/sessions/<pid>.json` 的 `status` 字段 |
| PID→pane 映射 | 自下而上：扫 `~/.claude/sessions/` 拿 pid → 沿 ppid 向上找祖先 pane |
| 项目路径 | 优取 session 文件 `cwd`，fallback `#{pane_current_path}` |
| 完成判定 | 进程退出（kill -0 失败）则条目移除；status=idle/waiting 视为等待人工干预 |
| 监控范围 | 可配置 current / all，由 monitor.sh 的参数决定，不同快捷键绑不同范围 |
| 面板形式 | 普通 tmux pane，tmux 自管可见性；插件靠 hook 挂可见/不可见开关 |
| 列表内容 | 状态(最显眼) \| agent名 \| 项目路径 \| 运行时长 \| summary(末行输出) |
| 预览 | fzf 上下分屏 split preview，立即显示目标 pane 实时画面，比例可配 |
| 切换 | `tmux switch-client -t <session>:<window>.<pane>`，作用于当前 client |
| 切换后面板 | 不主动 kill；切走后自然不可见 → hook 停止扫描；切回 → 恢复扫描 |
| 快捷键 | 插件不绑任何快捷键，绑定示例仅写在 README |
| 交互 | fzf 做列表 + split preview |
| 安装 | TPM (Tmux Plugin Manager) |
| 配置 | tmux 变量 @agent-monitor-* |
| 架构 | 方案 A：纯 Bash + fzf |
| 刷新策略 | 面板可见时轮询扫描；不可见时 hook 关闭轮询，零占用 |
| 依赖 | fzf、jq；启动检查缺失则友好报错 |

## 3. 调研结果

### 调研 1：状态检测 — 不需要解析终端输出

Claude CLI 持续写入会话状态文件 `~/.claude/sessions/<pid>.json`：

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

`status` 字段含义：

| status | 含义 | 显示 |
|--------|------|------|
| `"busy"` | 正在工作 | ● busy |
| `"idle"` | 空闲，等待输入 | ○ idle |
| `"waiting"` + `waitingFor` | 等人操作（如权限批准） | ▲ waiting |

插件不需要解析终端关键词。Codex 等后续 agent 各自调研状态机制。

### 调研 2：项目路径获取

优先级：
1. Claude session 文件的 `cwd` 字段（最准）
2. `tmux display -t <pane> -p '#{pane_current_path}'`（tmux 实时维护）
3. `/proc/<pane_pid>/cwd`（等价 fallback）
4. `#{pane_start_path}`（最后兜底，不跟踪 cd）

## 4. 文件结构

```
~/.tmux/plugins/tmux-agent-monitor/
├── agent-monitor.tmux          # TPM 入口：设默认配置 + 暴露脚本路径；不绑键
├── scripts/
│   ├── monitor.sh              # 主面板：参数 scope(current/all)，起 fzf + 轮询
│   ├── scanner.sh              # 扫描 agent，输出 NDJSON
│   ├── preview.sh              # fzf split preview 脚本，capture-pane 实时画面
│   ├── switch.sh               # 执行 switch-client 切换
│   └── helpers.sh              # 共享函数：读配置、PID 映射、stale 校验
└── README.md                   # 安装 + 快捷键绑定示例
```

## 5. 配置变量

```
set -g @agent-monitor-processes "claude"          # 监听进程名，逗号分隔
set -g @agent-monitor-refresh-interval "2"        # 扫描间隔秒
set -g @agent-monitor-summary-lines "1"           # summary 取末尾几行
set -g @agent-monitor-preview-ratio "60"          # 预览占比 %（上下分屏）
set -g @agent-monitor-fzf-args ""                 # 额外 fzf 参数覆盖
```

## 6. 数据流

```
触发(快捷键 run-shell monitor.sh all/current)
        │ 捕获触发时 session_name (scope=current 用)
        ▼
   monitor.sh ── 创建/进入面板 pane ── 起 fzf(split preview)
        │                                   │
        │ 启动轮询循环                        │ --bind reload 定时刷新
        ▼                                   ▼
   scanner.sh ──NDJSON──> fzf 列表    preview.sh ──capture-pane──> 预览区
   (扫 sessions 目录                  (光标条目对应 pane 实时画面)
    → kill -0 验活
    → ppid 找祖先 pane
    → 取 status/cwd/uptime
    → capture-pane 取 summary)
        │
   选中回车 → switch.sh → tmux switch-client -t sess:win.pane
        │
   面板失焦(不可见) ── tmux hook ── 停止轮询循环
   面板复焦(可见)   ── tmux hook ── 恢复轮询循环
```

## 7. 组件职责

### agent-monitor.tmux（TPM 入口）
- 设置 `@agent-monitor-*` 默认值
- 暴露脚本绝对路径（供用户在 README 示例里绑定）
- 不含任何 `bind-key`

### monitor.sh（主面板）
- 接受参数 `scope`（current / all）
- scope=current 时捕获触发时 `#{session_name}`
- 创建/进入面板 pane，启动 fzf（上下分屏预览）
- 管理后台轮询循环，定时 `reload` fzf 列表
- 注册 tmux hook：面板可见→启动轮询，不可见→停止轮询
- 处理 fzf 选中结果，调 switch.sh

### scanner.sh（扫描器）
- 列 `~/.claude/sessions/*.json`，逐个：
  - `kill -0 <pid>` 验活，死的跳过
  - 沿 ppid 链向上找祖先，匹配到某 `pane_pid` → 得到 session:window.pane
  - scope=current 时过滤非当前 session
  - 取 status、cwd、startedAt 算 uptime
  - `capture-pane -p -t <pane>` 取末尾行做 summary（过滤 TUI 边框）
  - 输出一行 NDJSON
- 空结果时输出占位，fzf 显示 "No agents running"

### preview.sh（预览）
- 输入：fzf 当前条目（含目标 pane 坐标）
- `tmux capture-pane -ep -t <pane>` 抓实时画面渲染到预览区

### switch.sh（切换）
- 输入：目标 session:window.pane
- `tmux switch-client -t <session>` + `select-window` + `select-pane`

### helpers.sh
- 读 tmux option 配置
- PID→pane 映射
- stale 校验

## 8. NDJSON 数据格式

```json
{"status":"busy","agent":"claude","cwd":"/home/gotpl/project","target":"work:0.1","uptime":342,"summary":"正在分析代码..."}
```

## 9. 关键技术点

1. **PID→pane 映射**：自下而上扫 sessions 目录（agent 数 << pane 数），沿 ppid 找祖先 pane_pid
2. **fzf 实时刷新**：`--bind 'load:reload(...)'` 配合定时器，保持光标位置不重置
3. **预览立即显示**：放弃延迟（fzf 原生无延迟开关）；上下分屏避免遮挡列表
4. **可见性开关**：tmux hook 监听面板进入/离开焦点，start/stop 轮询，fzf 进程常驻保留状态

## 10. 待后续

- Codex 及其他 agent 的状态检测机制（各自调研）
- 无状态文件 agent 的降级方案（进程活跃度判断）
