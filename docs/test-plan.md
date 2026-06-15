# tmux-agent-monitor 手动测试计划

## 前提

```bash
# 1. 确认插件已加载
tmux show-option -gv @agent-monitor-processes
# 预期: claude

# 2. 确认依赖
which fzf jq
```

## 测试 1：空面板（无 agent）

**目的**：无 Claude 运行时，面板显示占位信息。

```bash
# 先杀掉所有 Claude
killall claude 2>/dev/null || true

# 在 tmux 里执行
bash ~/personal/tmux-agent-manage/scripts/monitor.sh all
```

**预期**：新 pane 打开，显示 "No agents running. Press enter to exit."，回车退出。

## 测试 2：单 Claude 列表 + 预览

**目的**：1 个 Claude 运行时列表正确，预览跟随光标。

```bash
# 开一个 Claude（在一个已有的 tmux pane 里）
cd ~/personal/tmux-agent-manage && claude

# 然后在另一个 tmux pane 里打开面板
bash ~/personal/tmux-agent-manage/scripts/monitor.sh all
```

**预期**：
- [ ] 列表显示 1 行：`● busy claude /home/gotpl/personal/tmux-agent-manage 0mXXs ...`
- [ ] 光标在该行上，下方 preview 区显示目标 pane 实时画面（能看到 Claude 的 TUI）
- [ ] ↑↓ 移动光标（如果只有一个 agent 则不明显）
- [ ] 状态颜色：busy=黄色, idle=绿色

## 测试 3：多 Claude 列表

**目的**：多个 Claude 时列表和光标行为。

**前置**：在不同 pane 里开 2-3 个 Claude（不同项目目录）。

**预期**：
- [ ] 列表每行一个 agent，按 scanner 输出顺序排列
- [ ] cursor 移动时 preview 下方画面跟随切换到不同 pane
- [ ] 项目路径、uptime 各不相同

## 测试 4：切换到目标 pane

**目的**：在面板里选中 agent 回车后跳转。

```bash
# 在面板列表里，光标移到某个 agent，回车
```

**预期**：
- [ ] 当前 client 跳转到目标 agent 所在 session:window.pane
- [ ] 面板 pane 保留（变为不可见），停止扫描
- [ ] 跨 session 也能跳（如果 agent 在另一个 session）

## 测试 5：Esc 退出

**目的**：Esc 关闭面板。

```bash
# 在面板 fzf 里按 Esc
```

**预期**：
- [ ] fzf 退出，面板 pane 恢复为空
- [ ] 后台 reload 循环已停止（`ps aux | grep 'sleep.*@agent'` 无残留）

## 测试 6：定时刷新

**目的**：列表每 N 秒自动刷新。

**前置**：至少 1 个 Claude 运行中，面板已打开。

```bash
# 观察预览画面是否实时更新（Claude 输出变化时）
# 开关 Claude（关掉一个）等几秒看列表是否消失对应行
```

**预期**：
- [ ] Claude 输出变化时预览画面实时更新
- [ ] 关掉 Claude → 几秒内对应行消失
- [ ] 新开 Claude → 几秒内新行出现
- [ ] 刷新不打断光标位置（cursor 停在原位置不变）

## 测试 7：scope=current 过滤

**目的**：只显示当前 session 的 agent。

**前置**：至少 2 个 tmux session，各自有 Claude 运行。

```bash
# 在 session A 执行
bash ~/personal/tmux-agent-manage/scripts/monitor.sh current
```

**预期**：
- [ ] 只显示 session A 里的 agent
- [ ] session B 的 agent 不出现

## 测试 8：可见性开关

**目的**：面板不可见时停止扫描。

```bash
# 开监控面板
bash ~/personal/tmux-agent-manage/scripts/monitor.sh all

# 切到其他 window
Ctrl-b n

# 检查后台是否有 reload 活动
ps aux | grep -E 'scanner.sh|format_stream' | grep -v grep
```

**预期**：
- [ ] 切走后 `#{pane_active}` 变为 0，reload 循环 skip
- [ ] ps 看不到 scanner.sh 进程活动（可能有 sleep 挂着，但没有 scanner 执行）
- [ ] 切回监控面板 pane → 恢复刷新

## 测试 9：Ctrl-R 手动刷新

**目的**：fzf 里的 Ctrl-R 触发手动 reload。

```bash
# 在面板里按 Ctrl-r
```

**预期**：
- [ ] 列表立即重新加载（可能闪烁一下）
- [ ] 光标位置保持

## 测试 10：快捷键绑定（README 示例）

**目的**：确认用户绑定方式工作。

在 `~/.config/tmux/tmux.conf.local` 或 `~/.tmux.conf` 添加：

```tmux
bind-key g run-shell "~/.tmux/plugins/tmux-agent-manager/scripts/monitor.sh all"
```

然后 `prefix + g`。

**预期**：
- [ ] 弹出一个新 window/pane 显示监控面板
- [ ] 功能同手动执行 monitor.sh all

---

## 问题记录

| # | 现象 | 根因 | 修复 |
|---|------|------|------|
|   |   |   |   |
