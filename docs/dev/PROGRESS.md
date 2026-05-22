# macosAsr 开发进度（Living Log）

> 规格基线：**SDD v0.1.2**（设计参考；**以代码与根 README 为准**）  
> 分发目标：**GitHub 开源 + 开发者本机自建**（非 App Store）  
> 构建：**`scripts/build_macapp.sh`（swiftc）** — 无 Xcode 工程

## Current phase

**v0.1.x 开源基线** — P0 完成；**全局 ⌥Z Toggle**；设置页（语言）；README 中英双语；CI 冒烟

## Next actions（P1 候选）

1. Fn+V **PTT** 热键（按住说话，与当前 ⌥Z Toggle 并存或替代）
2. 三步权限 Onboarding
3. Settings 内可配置快捷键
4. Daemon 崩溃自动恢复
5. 多 App 兼容矩阵文档化

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
| 识别语言 | Chinese | Settings…；持久化 Application Support |
| 触发方式 | Fn+V PTT（P1） | **⌥Z Toggle**（全局 + 菜单）；菜单 Start/Stop 仍可用 |
| 全局热键权限 | 输入监控 | **输入监控** + **辅助功能**（吞 ⌥Z 防 Ω） |
| Daemon 生命周期 | 常驻 | App 启动 warm；**Quit 时 shutdown** |
| 构建 | — | `swiftc` + `build_macapp.sh`（无 `.xcodeproj`） |

---

## 历史摘要

| 日期 | 内容 |
|------|------|
| 2026-05-21–22 | P0a–P0d、签名、warmUp、菜单四态 |
| 2026-05-22+ | 设置页、partial 0.5s、v0.1.0 tag、双语 README |
| 2026-05-22+ | 删 xcodeproj，文档与 PROGRESS 同步 |
| 2026-05-22+ | 全局 **⌥Z** Toggle（`CGEventTap`）；README / SDD 同步 |

Agent 交接归档见 [`archive/AGENT_HANDOFF.md`](./archive/AGENT_HANDOFF.md)。
