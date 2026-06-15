# macosAsr 改进清单（待执行）

> 本文件由一次完整代码审查产出（2026-06-12），供后续 agent 执行。
> 每项含：**问题位置 / 根因 / 修法 / 验证**。行号以审查时为准，若漂移请按函数名/代码片段定位。
> 执行纪律：只改与该条目相关的代码；改完按"验证"一节跑通再标记完成；可 commit，**不要 push**。
> 通用验证基线：`./scripts/ci_smoke.sh`（Python import + 冒烟）、`./scripts/test_p0c.sh`（Swift 编译 + 状态机自测）、`./scripts/build_macapp.sh`（swiftc 构建）。

---

## P0 — 排雷（低风险小改动，先做）✅ 代码完成，自动验证通过

> 2026-06-12 执行记录：P0-1/P0-2/P0-4 已加回归测试或源码护栏；P0-3 已删除空壳目录。已通过 `python3 -m unittest tests.test_partial_engine_utterance_id tests.test_source_guardrails`、`./scripts/ci_smoke.sh`、`./scripts/build_macapp.sh`。未执行需要 GUI/真实模型加载的手动验收（Settings 选 1.7B、⌘Q + `kill -STOP` 卡死 daemon）。

### [P0-1] 删除写死的本机绝对路径模型选项 ✅代码完成 / 手动验收待跑
- **位置**：`MacApp/macosAsrApp/AppConfig.swift:54-64`，`enum AsrModelPreset`。
- **根因**：`case qwen17BLocal` 的 rawValue 是 `/Users/jackwl/.cache/huggingface/hub/models--mlx-community--Qwen3-ASR-1.7B-8bit/snapshots/a8379a2e2f9e313c9292cdf1af4055ab56d50d55` —— 这是开源仓库里写死的某台机器的绝对路径。任何别人 clone 后在设置页选这个选项，daemon 直接 `FileNotFoundError`（`mlx_audio.get_model_path` 对"看起来像本地路径但不存在"的输入会直接抛错，不会回退下载）。
- **修法**：把 rawValue 改成 HuggingFace repo id：
  ```swift
  case qwen17B = "mlx-community/Qwen3-ASR-1.7B-8bit"
  ```
  同步更新 `displayName`（去掉 "(local)" 改 "Qwen3-ASR 1.7B"）和 `ConfigManager.swift` 里对 `AsrModelPreset` 的引用（`saveAdvancedDictationSettings` 的校验、`AppConfig.swift` 的 `defaultAsrModel` 不受影响）。
- **已验证结论（重要，不用再测）**：repo id 命中本地缓存时**不会重新下载**（实测零字节、1.96s 返回同一 snapshot）；代价是每次启动多约 2s 联网校验。断网时会等连接超时后回退本地缓存（实测 `HF_HUB_OFFLINE=1` 下 0.01s 命中）。本条只做"一行版"，**不要**顺手加离线探测逻辑（见 P3-3）。
- **验证**：`build_macapp.sh` 编译通过；启动 App → Settings 选 1.7B → 重启 App → `tail log/daemon.log` 确认 `Loading model: mlx-community/Qwen3-ASR-1.7B-8bit` 且加载成功、无下载。
- **执行记录**：`AsrModelPreset.qwen17B` 已改为 HF repo id，displayName 已去掉 `(local)`；新增源码护栏防止 `/Users/` 模型路径回归。自动验证通过；GUI 设置页/模型加载未手动跑。

### [P0-2] 修复 ⌘Q 退出时 shutdown 逻辑倒置（可能挂死）✅代码完成 / 手动验收待跑
- **位置**：`MacApp/macosAsrApp/DaemonManager.swift:106-111`，`shutdown()` 末尾。
- **根因**：
  ```swift
  if let proc = daemonProcess, proc.isRunning {
      proc.waitUntilExit()   // 无限期阻塞，无超时
      if proc.isRunning {    // waitUntilExit 返回后必为 false
          proc.terminate()   // 死代码，永远到不了
      }
  }
  ```
  `terminate()` 兜底永远不触发。若 daemon 卡在 MLX 推理没响应 `shutdown` 命令，App 会永久挂在 `applicationWillTerminate`，只能强杀。
- **修法**：改成带超时的等待，超时后 `terminate()`，再不行 `SIGKILL`：
  ```swift
  if let proc = daemonProcess, proc.isRunning {
      let deadline = Date().addingTimeInterval(3.0)
      while proc.isRunning && Date() < deadline {
          Thread.sleep(forTimeInterval: 0.1)
      }
      if proc.isRunning {
          proc.terminate()                        // SIGTERM
          Thread.sleep(forTimeInterval: 0.5)
          if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
      }
  }
  ```
- **验证**：正常 ⌘Q → `pgrep -f asr_daemon` 无残留；手动让 daemon 卡死（如 `kill -STOP <pid>` 后再 ⌘Q）→ App 应在约 3.5s 内退出而非挂死。
- **执行记录**：`waitUntilExit()` 已替换为 3s bounded wait，超时后 `terminate()`，再 0.5s 后 `SIGKILL`。新增源码护栏防止无超时等待回归。自动验证通过；真实 GUI 退出/卡死 daemon 验收未手动跑。

### [P0-3] 删除空壳实验目录 ✅完成
- **位置**：`experiments/llm_postedit/`（仅剩 `__pycache__/` 和空 `reports/`，源码已不存在）。
- **修法**：`rm -rf experiments/llm_postedit`；若 `experiments/` 随之为空也一并删。检查 `.gitignore` 是否有相关条目需清理。
- **验证**：`git status` 干净；`ci_smoke.sh` 通过（确认无文件 import 了该目录）。
- **执行记录**：已删除 `experiments/llm_postedit/` 及空的 `experiments/`。`ci_smoke.sh` 通过；当前 `git status` 仍包含本轮代码/测试/todo 文档改动，非目录残留。

### [P0-4] 修正或删除 `utterance_id` 语义错误 ✅完成
- **位置**：`asr/partial_engine.py:349-353`，`_emit_partial()`。
- **根因**：每发一次 partial 就 `self._utterance_id += 1`。同一句话的多个 partial 拿到递增 ID（1,2,3...），final 拿到最后一个值。该字段语义本应是"第几句话"，现在实际是"第几次刷新"。Swift 端 `LiveDictationController.handle`（`LiveDictationController.swift:44-65`）根本不消费 `utterance_id`，所以目前没炸——但留着一个语义错误的协议字段是坑，未来谁基于它做"按句替换/撤销"必踩。
- **修法（二选一，倾向 A）**：
  - **A（修对）**：把 `self._utterance_id += 1` 移到"一句话开始"的位置（`_drain_audio_blocks` 里新建 `_UtteranceState` 时 +1），partial/final 复用同一 ID。这样 ID 真正标识句子，保留协议语义正确性；P2-2 撤销功能后续已决定不采用。
  - **B（删除）**：若短期不做按句功能，直接从 IPC 事件 payload（`session.py` 的 `on_partial/on_final/on_filtered`）中移除 `utterance_id` 字段，Swift 端 `DaemonEvent` 同步删。
- **验证**：`tests/` 下加/改断言：同一 utterance 的 partial 与其 final 携带相同 `utterance_id`（方案 A）；或事件无该字段（方案 B）。`ci_smoke.sh` 通过。
- **执行记录**：采用方案 A。`utterance_id` 在 `_UtteranceState` 创建时递增，同一句 partial/final 复用同一 ID；新增双 partial + final 回归测试。`ci_smoke.sh` 通过。

---

## P1 — 可靠性核心（常驻工具的底线）

### [P1-1] daemon 崩溃自愈 + send 失败检测 ✅代码完成 / 手动验收待跑
- **位置**：`MacApp/macosAsrApp/DaemonManager.swift`（进程生命周期、状态机）、`MacApp/macosAsrApp/DaemonClient.swift:77-90`（`send` 是 fire-and-forget，write 失败连日志都没有）。
- **根因**：Python 进程 OOM / MLX 报错退出后，App 的 `state` 仍停在 `.ready`/`.listening`，用户按 ⌥Z 没任何反应也没报错——核心路径静默失效。
- **修法**：
  1. 给 `launchDaemon` 里的 `Process` 设 `terminationHandler`，进程异常退出时把 `state` 置 `.error`，并清理 `clientConnected` / stale socket。
  2. `DaemonClient.send` 的 `write` 返回值 `< 0` 时记日志并回调一个失败通知（让 `DaemonManager` 感知连接已断）。
  3. `.error` 状态下用户再次触发 ⌥Z（`AppDelegate.toggleLiveDictation`）时，自动走一次 `warmUp()`（respawn），而不是静默 return。注意避免无限重启风暴：加重启计数 + 退避（如连续失败 3 次后停止并在菜单显示明确错误）。
- **验证**：App ready 后 `pkill -9 -f asr_daemon` → 菜单栏应在数秒内变 `⚠️ ASR`；再按 ⌥Z → 应自动 respawn 并恢复到可用，或在达到重试上限后给明确提示。`tail log/macapp.log` 有 `daemon_state ... -> error` 与 respawn 记录。
- **执行记录**：`DaemonClient.send` 已增加 completion 和 send/read 失败回调，并设置 `SO_NOSIGPIPE`；`DaemonManager` 已增加 `terminationHandler`、统一 `markDaemonFailed`、stale socket 清理、连续失败 3 次限流；`AppDelegate` 的错误态菜单改为 `Restart ASR Daemon`，按 ⌥Z/菜单可触发 `warmUp()`。已通过 `python3 -m unittest discover -s tests`、`./scripts/ci_smoke.sh`、`./scripts/build_macapp.sh`。未跑真实 GUI `pkill -9 -f asr_daemon` 手动验收。

### [P1-2] 首次下载进度反馈
- **位置**：`MacApp/macosAsrApp/DaemonManager.swift`（菜单 title 状态）、`asr_daemon/__main__.py`（当前把 HF 进度条过滤掉了：`_log_filter` + `HF_HUB_DISABLE_PROGRESS_BARS=1`）、`MacApp/macosAsrApp/AppDelegate.swift:145-178`（`applyDaemonState` 四态显示）。
- **根因**：首次启动要下约 3GB 模型，菜单栏只显示 `⏳ ASR` 一挂十几分钟，README 还写"约 30 秒"。新用户第一次体验=卡死。
- **修法**：daemon 在下载阶段通过现有 IPC（或 ping 响应里加字段）上报下载进度百分比；App 把菜单 title 显示成 `⏳ 42%` 之类。最简实现：daemon 侧用 `huggingface_hub` 的下载回调/或解析进度，周期性 `_broadcast` 一个 `{"type":"download_progress","pct":N}` 事件；Swift 端 `DaemonEvent` + `applyDaemonState` 加一个 `.downloading(pct)` 子态。
- **注意**：别破坏 `_log_filter` 对 daemon.log 噪音的抑制——进度走 IPC 事件而非 stdout。
- **验证**：清掉某个模型缓存（或用未缓存的 repo id）启动 App → 菜单栏出现递增百分比；下完转 `🎤 ASR`。

### [P1-3] partial 推理 O(n²)，长句拖垮"边说边出字" ✅代码完成 / 手动验收待跑
- **位置**：`asr/partial_engine.py:318-330`，`_process_active_utterance()` 里 `stream_utterance_text(self._model, utterance.blocks, cfg)`。
- **根因**：每 0.5s 调一次 partial，每次都对**整句的全量音频**重新推理（不是增量）。说到第 15s 时每次 partial 要推理 15s 音频，推理耗时一旦超过 `partial_interval_seconds`，"live 感"直接崩，且 GPU 在长句期间满转。
- **修法（最简，不动 mlx_audio）**：utterance 累计时长超过阈值（建议 8s，做成 `AsrConfig` 字段如 `partial_max_audio_seconds: float = 8.0`）后**停发 partial**，只等 VAD 触发 final 修正。屏幕上此时已有足够多的字，final 会一次性纠正。
- **修法（可选进阶，风险更高，需另立条目评估）**：滑动窗口 partial——只对最近 N 秒音频做 partial，配合 `InjectionStateMachine` 的前缀差分。**本次不做**，除非 P1-3 简化版实测仍然不够。
- **验证**：连续说 20s 长句，观察 partial 在 8s 后停止刷新、final 正常落字；`daemon.log` 里 partial 推理耗时不再随句长无限增长。
- **执行记录**：新增 `AsrConfig.partial_max_audio_seconds = 8.0`，`_process_active_utterance()` 超过窗口后跳过 partial 推理但保留 final；新增测试覆盖“超过窗口后不再调用 `stream_utterance_text`，final 仍输出”。已通过 `python3 -m unittest discover -s tests`。未跑真实 20s 长句手动验收。

---

## P2 — 核心体验补齐

### [P2-1] 听写中用户输入冲突保护 ✅代码完成 / 手动验收待跑
- **位置**：`MacApp/macosAsrApp/InjectionStateMachine.swift`（backspace-retype 假设"pending 区只有我在动"）、`MacApp/macosAsrApp/GlobalHotkeyMonitor.swift`（event tap 已在监听全局 keyDown，可复用）。
- **根因**：用户在听写中手动打字或点鼠标移光标后，下一次 partial 的退格会删掉用户自己刚输入的字符——目前**零防护**。这是 backspace-retype 注入方案能否在真实世界存活的关键。
- **修法**：listening 期间，`GlobalHotkeyMonitor` 的 event tap 检测到"非本 App 注入来源"的 keyDown / 鼠标点击时，通知 `InjectionStateMachine` 放弃当前 pending（`pendingText = ""`，**不再退格**），后续 partial/final 只追加不回删。
  - 注意区分"自己注入的 CGEvent"与"用户真实按键"：可用 `CGEventSource` 的 `userData`/`sourceStateID` 标记，或在注入窗口期设标志位临时忽略。
- **关联**：与 P2-3（注入挪出主线程）一起做更顺。
- **验证**：听写中途手动敲几个字 → 后续识别文字应追加在用户输入之后，不删用户的字。
- **执行记录**：`TextInjector` 给本 App 注入的 CGEvent 写入 `eventSourceUserData` 标记；`GlobalHotkeyMonitor` 扩展监听 keyDown / mouseDown，忽略自注入事件和 ⌥Z 本身，发现用户真实输入时通知 `LiveDictationController`；`InjectionStateMachine.onUserInputInterrupted()` 只清空 pending、不退格，后续 partial/final 不再回删用户刚输入的内容。新增 Swift 行为自测和源码护栏。已通过 `python3 -m unittest discover -s tests`、`./scripts/test_p0c.sh`。

### [P2-2] 撤销上一句（⌥⇧Z）❌不采用 / 已删除候选
- **位置**：新增热键逻辑（`GlobalHotkeyMonitor` 已有 event tap 框架）、`InjectionStateMachine`（已知 pending/上一句长度）。
- **原始动机**：ASR 必然出错，错字注入后用户只能手动删；理论上 App 可以按 final 长度退格。
- **放弃原因**：实际体验不稳定。当前跨 App 注入方案无法可靠知道目标编辑器的真实光标位置、选区和 undo 栈；按字符数退格会在 ASR/VAD 合并多句、用户移动光标、目标 App 自动改写文本时产生误删。后续即使按句末标点裁剪，也只是补丁，用户心智仍不清楚“撤销的是哪一段”。
- **决策**：不把 `⌥⇧Z` 撤销上一句作为当前产品功能合入；本轮未提交代码已移除。后续优先优化 ASR 准确率、VAD 分句、用户输入保护和手动编辑安全性。
- **未来再评估条件**：只有在能通过 Accessibility API 稳定读取目标控件文本/选区，并能在撤销前校验刚插入文本仍位于光标前方时，才重新考虑“精确撤销上一句”。

### [P2-3] 注入挪出主线程 ✅完成
- **位置**：`MacApp/macosAsrApp/DaemonClient.swift:135`（事件 dispatch 到 main）→ `LiveDictationController.handle` → `InjectionStateMachine` → `TextInjector.typeText`（`TextInjector.swift:36-50`，同步循环 + 每字符 `usleep(400)`）。
- **根因**：长 partial 的注入在主线程同步跑，每字符 400µs，长文本会卡 UI / 菜单无响应。
- **修法**：把注入放到专用串行后台队列（`DispatchQueue(label: "com.macosasr.injection")`），保证顺序性。注意 `pendingText` 状态的线程安全（注入队列单线程访问即可，但 partial 事件来自 main，需把状态变更也收敛到该队列）。
- **验证**：注入长文本时菜单栏/UI 仍可响应；文字顺序无错乱。
- **执行记录**：`InjectionStateMachine` 已增加 `com.macosasr.injection` 专用串行队列；`onPartial/onFinal/onFiltered/onSessionStopped` 只负责入队，退格/打字与 `pendingText` 读写都在注入队列执行；`pendingLen` 改为队列安全读取。新增源码护栏和生产状态机自测，防止事件入口重新同步调用 `injector` 或回到主线程注入。已通过 `python3 -m unittest tests/test_p2_injection_queue_guardrails.py`、`./scripts/test_p0c.sh`、`./scripts/ci_smoke.sh`、`./scripts/build_macapp.sh`。

### [P2-4] 麦克风常开 → 隐私观感问题 ✅代码完成 / 手动验收待跑
- **位置**：`asr_daemon/server.py:77`（daemon 启动即 `start_background_mic()`）、`asr/partial_engine.py`（`start_background_mic` / `stop` / 校准）。
- **根因**：daemon 一启动麦克风就常开（不听写时也采集只是丢弃），macOS 橙色录音指示器**全程亮着**。对主打"音频不出本机"的隐私产品是观感硬伤。
- **修法**：校准完成后关闭 InputStream；`session_start` 时再开（InputStream 启动 <100ms，体感无差）。需重构 `PartialEngine` 让 mic 流可反复开关，且校准逻辑只在首次或重新校准时跑。
- **权衡**：会增加 PartialEngine 状态复杂度。若评估收益不值，可降级为"文档说明"。**先评估再动手。**
- **验证**：App ready 但未听写时，菜单栏录音橙点应熄灭；按 ⌥Z 后亮起，停止后熄灭；听写功能不受影响。
- **执行记录**：`PartialEngine` 新增 `start_recording()` / `stop_recording()` 和 `recording_active`；daemon 启动时仍临时开麦完成噪声校准，校准后立即关闭 InputStream；`SessionController.start_session()` 先开麦再置 listening，`stop_session()` flush 后关麦；status payload 增加 `recording_active` 便于调试。新增 session 调用顺序测试、fake sounddevice 开关流测试和源码护栏。已通过 `python3 -m unittest discover -s tests`、`./scripts/test_p0c.sh`。

### [P2-5] 重新校准噪声菜单项
- **位置**：`asr/partial_engine.py:223-251`（`_calibrate_noise` 只在启动跑一次）、`asr_daemon/server.py`（`_dispatch` 加命令）、`AppDelegate.swift`（加菜单项）。
- **根因**：启动时安静、用着环境变吵或换麦克风后阈值漂移，无法重新校准。
- **修法**：IPC 加 `recalibrate` 命令 → daemon 重跑校准；菜单加 "Recalibrate Noise…" 项转发该命令。低成本。
- **验证**：点菜单项 → `daemon.log` 出现新的 `VAD threshold=... noise_floor=...` 行。

---

## P3 — 明确不做 / 推迟（记录决策，避免反复)

### [P3-1] PTT（Fn+V 按住说话）— 不做
- PROGRESS.md 的 P1 候选 #1。⌥Z Toggle 已 work，PTT 是第二种输入模态，需在 `GlobalHotkeyMonitor` 加 keyUp 配对 / 长按判定 / 与 Toggle 共存，复杂度翻倍，仅换交互偏好。**先把 Toggle 可靠性做满**（见 P1）。除非有真实用户反馈，否则不做。

### [P3-2] 三步权限 Onboarding 向导 — 不做
- 目标用户是"会 clone 和 build 的开发者"，README 的 6/6b 节已足够。给会开车的人画斑马线。

### [P3-3] Settings 内可配置快捷键 — 推迟
- ⌥Z 未收到真实冲突反馈前，是想象中的需求。

### [P3-4] 模型路径离线探测（HF_HUB_OFFLINE 自动设置）— 推迟
- P0-1 只做一行版。+2s 启动校验和"上游更新触发重下"都是低概率/低痛点，不预付复杂度。等真撞上（如频繁断网使用）再加约 10 行缓存探测兜底。

### 外围设施 — 保留不动，但别再加
- `install_desktop_shortcut.sh` / `install_login_item.sh` / `sync_repo_launcher.sh` / `build_icon.sh`：已写完、维护成本低，留着。**不要再加第四种启动方式。**

---

## 建议执行顺序
1. **P0 全部**（排雷，半天）：P0-1 / P0-2 / P0-3 / P0-4。
2. **P1-1**（daemon 自愈，可靠性的根）。
3. **P1-3 + P2-3 + P2-1**（长句性能 + 注入挪线程 + 输入保护，三者关联，一起做）。
4. **P1-2**（下载进度，补首次体验断点）。
5. **P2-5** 按需。
6. **P3 不做**。

## 文档同步提醒
- 改动落地后，同步更新 `docs/dev/PROGRESS.md`（里程碑表 + Next actions）与 `README.zh-CN.md`/`README.md`（若涉及用户可见行为，如下载进度、撤销热键、模型选项变化）。
