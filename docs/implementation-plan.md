# Plan: tmux-agent-monitor (rewrite)

**Source**: `docs/architecture.md` + 实地调研（2026-06-18/19，本机 tmux 3.6 / fzf 0.72 / jq 1.8，3 个 live Claude agent 实证）
**Replaces**: 旧实现（commit 629ed20，方案A 纯 Bash+fzf，脚本已从工作树删除）
**Complexity**: Medium

## Summary

重写 tmux-agent-monitor：保留"纯 Bash + fzf + jq、TPM 安装、不绑键、面板不可见零资源"的整体形态，但替换四个承重机制——PID→pane 改读进程 env 的 `TMUX_PANE`（一步直映，废弃 PPid 爬山）；预览改用一次性 split-pane 只换内容（解决 README 两个 TODO 及 split 生命周期竞态）；fzf 改 Unix-socket `--listen` + `--id-nth` 身份跟踪；agent 发现抽成 provider 接口，Claude 为首个 provider，Codex/通用 agent 留位。

## 调研结论（支撑本方案的实证）

1. **`TMUX_PANE` 直映**：claude 进程 `/proc/<pid>/environ` 带 `TMUX_PANE=%N`。3 个 agent 全部一步映射到正确 pane（含 nvim 嵌套）。env 缺失 = claude 不在 tmux 内 = 正确排除；PPid 链法区分不了"不在 tmux"与"链断"。
2. **pane_id 全局唯一且抗重排**：`tmux display-message -t %N -p '#{session_name}:#{window_index}.#{pane_index}'` 跨会话解析；`resize-pane -t %N -x -y` 按 pane_id 调整。pane_id 优于 `session:window.pane` 作内部句柄。
3. **fzf 0.72**：`--listen=path.sock`（Unix socket，无端口）；`--track --id-nth` 按 pane_id 身份跨 reload 跟踪光标；`focus:execute-silent(...)` 事件可拿到当前行字段（驱动预览同步）；`change-preview-window`/`reload` 可用。
4. **popup 不可用于并存预览**：`tmux display-popup` 是 modal，接管 client，无法与交互中 fzf 同屏。真 1:1 预览只能 split-pane。
5. **预览完整性边界**：`capture-pane` 抓目标按自身宽度排版的画面。目标 ≤ 预览时 `resize-pane` **缩小**预览到目标尺寸可真 1:1（缩小不受窗口上限 clamp，安全）；目标 > 预览时放大被窗口上限 clamp 且与 fzf 抢空间，无法 1:1 → 接受截断 + 滚动补看。`capture-pane` 仅支持竖向 offset（`-S`），无横向起点参数 → 横向滚动须对已抓字符串做 ANSI-aware 列裁剪（不能硬砍色码）。`popup` 是 modal 无法与 fzf 并存，故用 split-pane。

## 文件结构

```
~/.tmux/plugins/tmux-agent-manage/
├── tmux-agent-manage.tmux        # TPM 入口：默认配置，不绑键
├── scripts/
│   ├── monitor.sh                # 主面板：建专用窗口 + split(fzf|preview) + 生命周期 + fzf 驱动
│   ├── scanner.sh                # 调度 providers，合并 NDJSON，scope 过滤
│   ├── providers/
│   │   ├── claude.sh             # Claude provider：扫 sessions/*.json + TMUX_PANE 映射
│   │   └── generic.sh            # 占位：进程树发现通用 agent（Codex 等，后续实现）
│   ├── preview.sh                # 预览 pane 内常驻循环：读 target 文件 → capture-pane 渲染
│   ├── switch.sh                 # pane_id → switch-client 跨会话切换
│   └── helpers.sh                # get_opt / require_deps / format_stream / stale 校验 / TMUX_PANE 读取
└── README.md
```

## Provider 接口

每个 provider 是独立可执行脚本，stdout 输出 NDJSON，每行一个 agent：

```json
{"pane_id":"%6","agent":"claude","status":"busy","cwd":"/home/gotpl/proj","started_at":1781790597182,"summary":"...","target":"0:2.1"}
```

- `pane_id`：主键，TMUX_PANE env 直取；无 tmux env 的 agent 不输出（out of scope）
- `target`：`session:window.pane`，由 pane_id 解析，供 switch/显示
- `status`：`busy` | `idle` | `waiting` | `unknown`（无状态文件的通用 agent 用 `unknown` + 活跃度推断）
- scanner.sh 读 `@agent-monitor-providers`（默认 `claude`），逐个 source/执行，合并去重（按 pane_id）

## 关键机制设计

### A. PID→pane（helpers.sh）

```bash
pane_id_from_pid() {  # $1=pid -> echo %N or empty
  tr '\0' '\n' < /proc/$1/environ 2>/dev/null | awk -F= '$1=="TMUX_PANE"{print $2; exit}'
}
```

主路径：读 env。Fallback（env 不可读但 agent 仍在 tmux 下）：沿 PPid 链找 `list-panes pane_pid`（旧逻辑降级保留，不作为主路径）。

### B. 预览：一次性 split-pane + 条件缩放 + 滚动补看

**完整性边界**（实测几何关系）：
- 目标 pane 宽高 ≤ 预览 pane（同尺寸/更小窗口）：`resize-pane -t preview -x W_t -y H_t` **缩小**预览到目标尺寸，真 1:1 完整，无需滚动。缩小不受窗口上限 clamp，安全，且缩小的预览让出空间给 fzf 列表。
- 目标宽高 > 预览（跨尺寸大窗口）：无法放大预览（窗口上限 clamp + 会与 fzf 抢空间），接受截断，靠滚动补看。
- 颜色安全：`capture-pane -ep` 抓的是目标按自身宽度排版的画面，每字符带自己的 `\033[...m` 色码原样流出；缩小路径不重排，颜色零破坏。截断路径需 ANSI-aware 裁剪（见下）。

**截断默认保留区**（不滚动时用户立刻看到的）：
- 高方向：保留**底部**（顶部截）。最新输出在底部，优先可见。`capture-pane -p -e -S <bottom - offset_y>` 调抓取起点。
- 宽方向：保留**左侧**（右侧截）。claude TUI 左侧主内容区信息密度高，右侧多为状态栏/边框。

**滚动（来回可逆，绝对偏移模型）**：
```
offset_y: 0 = 底部可见区, 正数 = 往上暴露历史行,  范围 [0, H_t - H_p]
offset_x: 0 = 左侧可见区, 正数 = 往右暴露列,      范围 [0, W_t - W_p]
shift-up:    offset_y = clamp(offset_y + 1, 0, max_y)
shift-down:  offset_y = clamp(offset_y - 1, 0, max_y)
shift-right: offset_x = clamp(offset_x + 1, 0, max_x)
shift-left:  offset_x = clamp(offset_x - 1, 0, max_x)
```
四键走 fzf `--bind`，写 offset 到 state 文件（小整数原子写）。

**来回滚动不卡死的 5 个堵点**：
1. 绝对偏移（非相对增量）：+1 再 -1 精确回到原值，无累积误差、天然可逆。
2. offset 存 state 文件，preview.sh 每周期重读 → 滚动状态跨刷新存活，不被刷新冲掉。
3. 每周期重算 `max_y/max_x` 并 re-clamp → 目标持续输出导致 `H_t` 变化时，旧 offset 越界自动 snap 回有效区，不卡在非法 offset。
4. 横向裁剪 ANSI-aware：`offset_x` 跳过 N 个**可见字符**（不计转义序列），裁剪点重建当前 SGR 前缀、结尾补 `\033[0m`。不能 `cut`/`awk` 硬砍（会砍在色码中间，颜色泄漏）。两方向都要测。
5. focus 换 target 时 `offset_x=offset_y=0`，回默认保留区（底/左）——不带上一个 agent 的滚动位置。

**split 方向**：默认**上下 split**（`split-window -v`）让预览拿满终端宽度。多数终端横屏，整行宽度常 ≥ 目标宽度，宽截断概率大降；高度截断只丢顶部，可滚动。`@agent-monitor-preview-position` 可配 `down`(上下) / `right`(左右)。

**结构**：
1. monitor.sh 建专用窗口，`split-window -v` 得到 `[ fzf pane / preview pane ]`（上列表下预览）
2. fzf pane 跑 fzf；preview pane 启动 `preview.sh` 常驻循环
3. fzf `--bind 'focus:execute-silent(echo {pane_id} > $STATE_DIR/current)'` —— focus 变化只写一个文件，**不重建 pane**（旧实现竞态根因）
4. fzf `--bind 'shift-up|shift-down|shift-right|shift-left'` 各写对应 offset 到 state 文件
5. preview.sh 循环：读 `current` + offset → 解析目标尺寸 → 条件 resize（只缩小）/ 截断渲染 → sleep → 清屏重绘
6. monitor.sh 退出（fzf abort/Esc）→ `kill-window` 整窗清理

**为何稳定**：preview pane 全程不销毁、不 send-keys，只重绘内容；target 和 offset 经文件传递，无跨进程竞态。

### C. fzf 驱动（monitor.sh）

- 列表：`scanner.sh | format_stream`（status 彩色列 + pane_id 作隐藏 id 字段）
- `--track --id-nth <pane_id 字段>`：光标按 agent 身份跨 reload 保持
- 刷新：`load:reload` 经审核验证为一次性触发（fzf `load` 事件不因 reload 结果再次触发），不可自维持。实际采用：fzf `--listen=$STATE_DIR/fzf.sock`（Unix domain socket）+ 后台 socat loop 按周期发送 `reload` 动作。`load:reload` 保留为一次性初始刷新（启动短暂延迟后更新到最新数据）。`ctrl-r` 手动刷新。均无需 TCP 端口。
- 可见性闸：reload 命令内查 `tmux display -t $MONITOR_PANE -p '#{pane_active}'`，非活跃时跳过扫描（保留旧实现务实路线，不押注 hook）
- enter：`execute(switch.sh {pane_id})+abort`；Esc/Ctrl-C：abort

### D. 生命周期

- fzf 进程存活 = 面板存活 = 允许扫描；fzf 退出 → trap EXIT → kill preview loop → kill-window
- 面板失焦（切走 session/window）：reload 命令查 `pane_active` 自动停扫，零资源
- state 目录：`/tmp/agent-monitor-$$/`（PID 隔离），EXIT 清理

## 配置变量

```
@agent-monitor-providers        "claude"        # 逗号分隔 provider 列表
@agent-monitor-refresh-interval "2"             # 秒
@agent-monitor-summary-lines    "1"
@agent-monitor-preview-position "down"          # down=上下split(默认,预览拿满宽) | right=左右split
@agent-monitor-preview-ratio    "50"            # split 预览占比 %
@agent-monitor-scroll-step      "1"             # shift 方向键滚动步长
@agent-monitor-fzf-args         ""
@agent-monitor-scope            "all"           # all | current
```

## NDJSON 格式

```json
{"pane_id":"%6","agent":"claude","status":"busy","cwd":"/home/gotpl/proj","started_at":1781790597182,"uptime":"5m12s","summary":"analyzing...","target":"0:2.1"}
```

## Tasks

### Phase 0: 脚手架 + 配置默认值
- 建目录 `scripts/providers/`；`tmux-agent-manage.tmux` 设上述默认值；`helpers.sh` 实现 `get_opt`/`require_deps`/`pane_id_from_pid`/`format_stream`/`strip_ansi`/`format_uptime`；所有脚本 shebang + `set -euo pipefail`
- **Validate**: `tmux source tmux-agent-manage.tmux && tmux show-option -gv @agent-monitor-providers` → `claude`

### Phase 1: fzf 刷新机制验证 ⚠️
- 验证 `--bind 'load:reload(sleep 2; seq 5)'` 是否自维持（reload 后 load 是否再触发）
- 验证 `--track --id-nth 1` 跨 reload 光标按字段身份保持
- 验证 `focus:execute-silent(echo {1} >/tmp/x)` 文件写入
- **Validate**: 三个最小 fzf 命令跑通；定下主路径（自维持）或降级（Unix-socket）

### Phase 2: providers/claude.sh + scanner.sh
- claude.sh：列 `~/.claude/sessions/*.json` → `kill -0` 验活 → `pane_id_from_pid` → 解析 target → 读 status/cwd/startedAt → capture-pane 末行 summary → 输出 NDJSON
- scanner.sh：读 providers 配置，逐个执行合并，scope=current 时按 session 过滤，空结果输出占位
- **Validate**: `bash scripts/scanner.sh all` 输出 3 个 agent 的正确 NDJSON（与本机实证一致）；杀某 claude 后该条消失

### Phase 3: switch.sh + preview.sh + ANSI 裁剪器 ⚠️
- switch.sh：入参 pane_id → `display-message` 解析 session → `switch-client` + `select-window` + `select-pane`
- preview.sh：常驻循环读 `current` + offset → 解析目标尺寸 → 条件 resize（只缩小，真 1:1）/ 截断渲染（高保留底、宽保留左）→ `capture-pane -ep -S <bottom-offset_y>` → 横向 ANSI 裁剪 → 清屏重绘；每周期 re-clamp offset
- ANSI 裁剪器（helpers.sh `ansi_crop`）：跳过 N 可见字符（不计转义序列），裁剪点重建 SGR 前缀、结尾补 `\033[0m`。**重点测横向来回滚动不破色**
- **Validate**: `switch.sh %6` 跳到目标 pane；preview.sh 单跑持续刷新；目标 ≤ 预览时真 1:1 缩小；目标 > 预览时高保底/宽保左截断；四向 shift 滚动来回可逆、到边界停、不破色；换 target offset 清零

### Phase 4: monitor.sh 主面板
- 建专用窗口 + split；fzf 配 Phase 1 定的刷新机制 + `--track --id-nth` + focus 写文件 + enter 调 switch + Esc abort；trap EXIT 清理
- **Validate**: `monitor.sh all` 出完整面板；列表/预览/切换/reload 光标不跳；切走停扫、切回恢复

### Phase 5: README + 端到端
- README：安装、配置表、绑键示例、status 图例、工作原理（含 TMUX_PANE 直映 + split 预览 + 完整性边界与滚动说明）
- 真实工作流：多 session 多 claude 走一遍列表/预览/跨会话切换/可见性停扫
- **绑键示例**:
  ```tmux
  bind-key g run-shell "~/.tmux/plugins/tmux-agent-manage/scripts/monitor.sh all"
  bind-key G run-shell "~/.tmux/plugins/tmux-agent-manage/scripts/monitor.sh current"
  ```

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| `load:reload` 不自维持 | Medium | Phase 1 先验证；降级 Unix-socket `--listen` |
| 横向 ANSI 裁剪破色（来回滚动） | Medium | Phase 3 单独写 `ansi_crop` 并测；跳转义序列、裁剪点重建 SGR；两方向都测 |
| 滚动 offset 被刷新冲掉 / 越界卡死 | Medium | offset 存 state 文件跨刷新存活；每周期 re-clamp 到 `max_y/max_x`；换 target 清零 |
| 预览 resize 与 fzf 抢窗格尺寸 | Low | 只缩小不放大（缩小让出空间给列表），放大场景改走截断+滚动不 resize |
| 目标 > 预览无法真 1:1 | Low | 几何限制无法消除；截断保底/保左 + 滚动补看 + 预览顶部标注 `truncated` 提示 |
| TMUX_PANE env 对非 tmux 启动的 claude 缺失 | Low | 正确行为：out of scope 不显示；PPid fallback 兜底 env 不可读但仍在 tmux 下的边角 |
| 通用 agent（Codex）无状态文件 | Medium | Phase 2 留 generic.sh 占位，后续单独调研 |

## Acceptance

- [ ] Phase 0: TPM 加载无报错，默认配置正确
- [ ] Phase 1: fzf 刷新机制选定并验证（自维持或 socket 降级）
- [ ] Phase 2: scanner 输出正确 NDJSON，TMUX_PANE 直映，stale 校验有效
- [ ] Phase 3: switch/preview 单独可用；条件 resize（只缩小真 1:1）、截断保底/保左、四向滚动来回可逆不破色、换 target 清零
- [ ] Phase 4: 完整面板可交互，reload 光标按身份保持，可见性停扫
- [ ] Phase 5: README 完整，端到端多 session 验证通过
