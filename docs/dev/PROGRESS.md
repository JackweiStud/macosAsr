# macosAsr 开发进度（Living Log）

> 规格基线：**SDD v0.1.2**（设计参考；**以代码与根 README 为准**）  
> 分发目标：**GitHub 开源 + 开发者本机自建**（非 App Store）  
> 构建：**`scripts/build_macapp.sh`（swiftc）** — 无 Xcode 工程

## Current phase

**v0.1.x 开源基线** — P0 完成；**全局 ⌥Z Toggle**；设置页（语言/模型/听写参数）；README 中英双语；CI 冒烟；2026-06-12 P0 review hardening 已落地

## Next actions（P1 候选）

1. Daemon 崩溃自愈 + IPC send 失败检测
2. 长句 partial 推理上限，避免 O(n²) 拖垮 live 体验
3. 注入挪到后台串行队列，并加入听写中用户输入冲突保护
4. 首次模型下载进度反馈
5. 撤销上一句热键（候选：⌥⇧Z）

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
| ASR 模型 | Qwen3-ASR-0.6B | Settings…；默认 `mlx-community/Qwen3-ASR-0.6B-8bit`，可选 `mlx-community/Qwen3-ASR-1.7B-8bit` |
| 触发方式 | Fn+V PTT（P1） | **⌥Z Toggle**（全局 + 菜单）；菜单 Start/Stop 仍可用 |
| 全局热键权限 | 输入监控 | **输入监控** + **辅助功能**（吞 ⌥Z 防 Ω） |
| Daemon 生命周期 | 常驻 | App 启动 warm；**Quit 时 shutdown**；退出最多等待约 3.5s 后 TERM/KILL 兜底 |
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

Agent 交接归档见 [`archive/AGENT_HANDOFF.md`](./archive/AGENT_HANDOFF.md)。
