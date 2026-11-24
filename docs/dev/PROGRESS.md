# macosAsr 开发进度（Living Log）

> 规格基线：**SDD v0.1.2**（设计参考；**以代码与根 README 为准**）  
> 分发目标：**GitHub 开源 + 开发者本机自建**（非 App Store）  
> 构建：**`scripts/build_macapp.sh`（swiftc）** — 无 Xcode 工程

## Current phase

**v0.2.x 流式与准确率突破** — 已完成全局 **⌥Z Toggle**、设置页热更新、后台注入、按需开麦、以及 2026-11 四项 ASR 核心突破：
1. 修复 `partial` 逐 BPE Token 吞空格 Bug，补齐句内跨窗 `committed` 前文接力与打断脏上下文清理
2. 落地 **Qwen3-ASR 原生 8s `AudioEncoder` 块缓存 + Assistant Prefix Rollback 流式引擎**（`asr/streaming_decoder.py`），32s 长句实测 `max_partial_ms=374ms`、0 次切窗对齐失败
3. 落地 **语义标点双速断句**（`asr/endpointing.py`）与 60 分位抗噪启动校准 + 空闲底噪向下自愈
4. 落地 **Settings 自定义热词词典热更新** + **可选本地屏幕/光标语境读取（默认关闭、跳过密码框）** + **短噪声 Prompt 回声幻觉过滤**

## Next actions（体验候选）

1. 首次模型下载进度反馈
2. 重新校准噪声菜单项
3. 固定音频样本自动化评测脚本（`docs/fix/p2-1-asr-evaluation-loop.md`）

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
| P1-3 partial 限流 / 长句滚动提交 | ✅ | 单句约 8s 滚动提交 final 并继续新一句 partial，避免长口述 live 停更 |
| P2-1 输入保护 | ✅ | 听写中用户键盘/鼠标输入会丢弃当前 pending，后续不回删用户内容 |
| P2-3 后台注入 | ✅ | `InjectionStateMachine` 通过 `com.macosasr.injection` 串行队列执行退格/打字；主线程只入队 |
| P2-4 按需开麦 | ✅ | 启动校准后关闭麦克风；session start/stop 控制 InputStream |
| 突破点 1：空格修复与句内前文 | ✅ | 修复 partial BPE 吞空格闪烁；跨窗接力 `committed` 前文；160ms 平滑停顿切点与惰性 prefix 解码 |
| 突破点 2：Qwen3 原生块缓存流式 | ✅ | `asr/streaming_decoder.py` 复用 8s AudioEncoder 块特征 + Assistant Prefix Rollback，彻底消除 8s 切窗卡顿与对齐失败 |
| 突破点 3：语义标点双速断句 | ✅ | `asr/endpointing.py` 区分闭合句末快收口（0.9–1.0s）与悬空词/思考停顿完整等待（2.0s），校准改 60 分位并支持空闲向下自愈 |
| 突破点 4：热词词典与可选屏幕语境 | ✅ | Settings 预置开发热词支持增删改即时热更新；`ScreenContextReader` 默认关闭、自动跳过密码框；增加 Prompt 回声过滤护栏 |
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
| partial_interval | 0.25s | **0.5s**（Settings 实时热更新；`MACOSASR_PARTIAL_INTERVAL` 可覆盖） |
| native_streaming | — | **True**（`Qwen3StreamingSession`：8s 块缓存 + `unfixed_tokens=6` 前缀回退，单段上限 48s 自动封窗续写） |
| semantic_endpointing | — | **True**（闭合句末快通道 `0.50x`/问句 `0.45x`，下限 `0.80s`；未闭合/悬空词保持完整 `vad_end_silence`） |
| 自定义热词 / 屏幕语境 | — | Settings 预置开发热词热更新；屏幕/光标语境默认 **OFF**（本地只读、自动跳过密码框） |
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
| 2026-08-18 | 长句滚动提交：8s 左右提交当前段并继续听写；实机 10s/18s 长口述未再出现连续卡顿，准确率无明显下降 |
| 2026-06-12 | P2-3 后台注入：partial/final/filter 只入队，退格/打字和 pending 状态收敛到专用串行队列 |
| 2026-06-15 | P2-1/P2-4：用户输入保护；启动校准后关麦，听写 session 按需开关麦克风 |
| 2026-10-16 | `RollingTranscript`：分离 8s 计算窗口与语义定稿，跨窗保持同一 `utterance_id` |
| 2026-11-24 | 四项核心突破落地：BPE 空格修复 + Qwen3-ASR 原生 8s 块缓存/Prefix Rollback 流式 + 语义标点双速断句 + Settings 热词热更新/可选 AX 屏幕语境/Prompt 回声过滤 |

Agent 交接归档见 [`archive/AGENT_HANDOFF.md`](./archive/AGENT_HANDOFF.md)。
