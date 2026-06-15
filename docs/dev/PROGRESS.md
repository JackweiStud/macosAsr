# macosAsr 开发进度（Living Log）

> 规格基线：**SDD v0.1.2**（设计参考；**以代码与根 README 为准**）  
> 分发目标：**GitHub 开源 + 开发者本机自建**（非 App Store）  
> 构建：**`scripts/build_macapp.sh`（swiftc）** — 无 Xcode 工程

## Current phase

**v0.1.x 开源基线** — P0 完成；**全局 ⌥Z Toggle**；设置页（语言/模型/听写参数）；README 中英双语；CI 冒烟；2026-06-12 P0 review hardening、P1-1 daemon 自愈、P1-3 partial 限流、P2-1 输入保护、P2-3 后台注入、P2-4 按需开麦已落地

## Next actions（体验候选）

1. 首次模型下载进度反馈
2. 重新校准噪声菜单项
3. 首次下载/加载状态文档校准

---

## 里程碑

| 阶段 | 状态 | 说明 |
|------|------|------|
| P0a ASR + Daemon | ✅ | `asr/` + `asr_daemon` IPC |
| P0b IPC 门禁 | ✅ | T-02/T-03 PASS |
| P0c Mock 注入 | ✅ | 备忘录注入 |
| P0d Live 听写 | ✅ | 菜单 Start/Stop + final |
| 全局 ⌥Z Toggle | ✅ | `GlobalHotkeyMonitor` + `CGEventTap`；需输入监控 + 辅助功能 |
| 稳定签名 + warmUp | ✅ | `macosAsr Local`、菜单四态 |
| 设置页（语言） | ✅ | Application Support `config.json` |
| P0 review hardening | ✅ | 移除本机模型路径；Quit bounded shutdown；修正 utterance_id；删空实验目录 |
| P1-1 daemon 自愈 | ✅ | daemon 退出/send 失败进入 `⚠️ ASR`；错误态可重启；连续失败限流 |
| P1-3 partial 限流 | ✅ | 单句超过约 8s 后停止 partial 刷新；final 仍完整输出 |
| P2-1 输入保护 | ✅ | 听写中用户键盘/鼠标输入会丢弃当前 pending，后续不回删用户内容 |
| P2-3 后台注入 | ✅ | `InjectionStateMachine` 通过 `com.macosasr.injection` 串行队列执行退格/打字；主线程只入队 |
| P2-4 按需开麦 | ✅ | 启动校准后关闭麦克风；session start/stop 控制 InputStream |
| v0.1.0 开源准备 | ✅ | LICENSE、pin deps、CI、双语 README |
| 移除 xcodeproj | ✅ | 仅 swiftc 构建 |

---

## 日常使用

```bash
./scripts/launch_macapp.sh
./scripts/install_desktop_shortcut.sh   # 可选
./scripts/install_login_item.sh install # 可选
```

Quit（⌘Q）关闭 App **并** shutdown daemon。

---

## 默认参数（当前实现）

| 参数 | SDD 默认 | 当前 |
|------|----------|------|
| partial_interval | 0.25s | **0.5s**（`MACOSASR_PARTIAL_INTERVAL` 可覆盖） |
| partial_max_audio | — | **8.0s**；超过后暂停 partial，等待 final |
| 识别语言 | Chinese | Settings…；持久化 Application Support |
| ASR 模型 | Qwen3-ASR-0.6B | Settings…；默认 `mlx-community/Qwen3-ASR-0.6B-8bit`，可选 `mlx-community/Qwen3-ASR-1.7B-8bit` |
| 触发方式 | Fn+V PTT（P1） | **⌥Z Toggle**（全局 + 菜单）；菜单 Start/Stop 仍可用 |
| 文本注入 | 主线程同步注入 | 后台串行队列注入，保持顺序并降低菜单/UI 卡顿 |
| 用户输入冲突 | — | 听写中检测到用户键盘/鼠标输入后放弃 pending，不再退格旧 ASR 文本 |
| 麦克风生命周期 | 常驻 | 启动校准和听写时打开；ready 但未听写时关闭 |
| 全局热键权限 | 输入监控 | **输入监控** + **辅助功能**（吞 ⌥Z 防 Ω） |
| Daemon 生命周期 | 常驻 | App 启动 warm；异常退出/IPC 断开进入 `⚠️ ASR`；错误态可重启；**Quit 时 shutdown**；退出最多等待约 3.5s 后 TERM/KILL 兜底 |
| 构建 | — | `swiftc` + `build_macapp.sh`（无 `.xcodeproj`） |

---

## 历史摘要

| 日期 | 内容 |
|------|------|
| 2026-05-21–22 | P0a–P0d、签名、warmUp、菜单四态 |
| 2026-05-22+ | 设置页、partial 0.5s、v0.1.0 tag、双语 README |
| 2026-05-22+ | 删 xcodeproj，文档与 PROGRESS 同步 |
| 2026-05-22+ | 全局 **⌥Z** Toggle（`CGEventTap`）；README / SDD 同步 |
| 2026-06-12 | P0 review hardening：模型 preset 去本机路径、Quit 退出兜底、`utterance_id` 语义修正、删除空实验目录 |
| 2026-06-12 | P1-1 daemon 自愈：`terminationHandler`、send/read failure 回调、错误态重启与限流 |
| 2026-06-12 | P1-3 partial 限流：8s 后停止整句重复推理，保留 final 修正 |
| 2026-06-12 | P2-3 后台注入：partial/final/filter 只入队，退格/打字和 pending 状态收敛到专用串行队列 |
| 2026-06-15 | P2-1/P2-4：用户输入保护；启动校准后关麦，听写 session 按需开关麦克风 |

Agent 交接归档见 [`archive/AGENT_HANDOFF.md`](./archive/AGENT_HANDOFF.md)。
