# 长句 live 听写停更：问题、修复与验证

- 日期：2026-08-18
- 分支：`codex/asr-accuracy-context-experiment`
- 状态：已按分段提交落地（默认开启）；实机长句听写反馈为流畅性明显改善，准确率无明显下降
- 相关代码：`asr/partial_engine.py`、`asr/asr_core.py`、`asr/config.py`

---

## 1. 问题是什么

产品承诺是「边说边出字」。用户连续说较长时间后，**屏幕上的字不再跟着长**，过一段时间才把后面整段一次性打出来。

这不是模型突然不会认中文，也不是注入层卡住。根因是当前「流式」其实是：

1. 对**当前整句全量音频**反复做离线识别（不是增量编码）
2. 句长超过 **8 秒** 后，**主动停发** `partial`
3. 音频继续攒着，直到 VAD 认为句末（或软/硬上限），再对**整段长音频**做一次 `generate`
4. 一条 `final` 把 8 秒之后的内容一次性注入

所以用户感知是：**前几秒有字 → 后面冻住 → 等一会儿 → 剩下的一次性涌出来。**

要区分两件容易混在一起的事：

| 现象 | 是不是本题 |
|------|------------|
| 说了 8 秒以上，字不再刷新，停嘴后才补齐 | **是** |
| 专名/同音字认错 | 不是（准确率另一条线） |
| 思考停顿被 1.5s 静音切句 | 不是（VAD 灵敏度） |
| 20 秒硬切把一句话截断 | 相关，但是下一节的软断句在修这个，**修不了停更** |

---

## 2. 修复前状态与当前代码

修复前，`f11a20b`（ASR VAD 长句软断句治理）仍没有取消 8 秒停发 `partial`，只是在更晚的时刻多了一种「较短静音也可以 final」的断句。

当前代码已经改为分段提交：达到滚动条件后先 final 当前段，再清空当前 utterance，让后续语音重新建句并恢复短窗 partial。`partial_max_audio_seconds` 不再是“停发 partial 后继续攒整句”的阈值，而是“滚动提交当前段”的阈值。

### 2.1 修复前怎么实现

修复前 Worker 单线程循环：收块 → 可能跑 partial → 再看要不要 final。

**Partial（live 字）**

```368:386:asr/partial_engine.py
        within_partial_window = (
            cfg.partial_max_audio_seconds <= 0
            or utterance_seconds <= cfg.partial_max_audio_seconds
        )

        if (
            utterance_seconds >= cfg.partial_min_audio_seconds
            and within_partial_window
            and now - utterance.last_partial_at >= cfg.partial_interval_seconds
        ):
            ...
            partial_text = stream_utterance_text(self._model, utterance.blocks, cfg)
            ...
                self._emit_partial(utterance.utterance_id, partial_text)
```

- 默认 `partial_max_audio_seconds = 8.0`，`partial_interval_seconds = 0.5`
- 每次把 **utterance 里全部 blocks** 拼成一段 16 kHz 音频
- `stream_utterance_text` 调用 mlx-audio 的 `stream_transcribe`：这是「整段已经齐了，再按 token 吐」，不是边收音频边解
- token 被攒完才 `on_partial` 一次，Swift 侧看不到 token 级流

超过 8 秒：`within_partial_window == False`，**不再发 partial**，但 `blocks` 继续追加。这正是长句听写停更的来源。

**Final（一次性补齐）** 修复前只有三条：

| reason | 条件 | 默认 |
|--------|------|------|
| `silence` | 静音 ≥ 句末阈值 | 1.50s |
| `soft_silence`（新） | 句长 ≥ 软上限 **且** 静音 ≥ 软断句静音 | 12.0s + 0.50s |
| `max_utterance` | 句长 ≥ 硬上限 | 20.0s |

`f11a20b` 只加了中间那条。它降低的是「顶到 20 秒被硬切」的概率，**不恢复 8 秒之后的 live 刷新**。

连续不停地说、中间没有 ≥0.5s 的静音：软断句不会触发，仍会走到 20 秒硬切，或停嘴后再等 1.5s。

原回归测试也锁定了「超过窗口就停 partial」：`test_partial_stops_after_max_audio_window_but_final_still_emits`。

### 2.2 修复前给用户的体验

以连续口述为例（数字为默认参数，推理耗时随机器/模型变化）：

```text
时间轴（用户一直在说）

0.0s     开始说话，VAD 建句
0.6s     第一条 partial（识别约 0.6s 音频）
1.1s     下一条 partial（识别约 1.1s 音频）
 ...     每 0.5s 一次，每次重跑「从句首到现在」的全量音频，越来越慢
8.0s     最后一次可能的 partial。之后屏幕冻在约前 8 秒的字
8–12s    还在说，无新 partial；字不长
12s      软上限到了，但没有 0.5s 静音 → 不断句
12–20s   继续冻；若中间有 ≥0.5s 换气，才 soft_silence final
20s      硬切：对约 20s 音频 generate，一次打出后面全部字
```

停嘴时：

```text
说了 15s，中间没有足够静音
  → 8s 后冻住
  → 停嘴后再等 1.5s 句末静音
  → generate(15s) 可能再耗 1s+
  → 一条 final 把 8s 之后的内容一次性注入
```

注入层（`InjectionStateMachine`）是前缀差分：`partial` 改 pending，`final` 对齐后清空 pending。冻住期间 pending 停在旧稿；`final` 到来时后缀一次性打出，看起来就是「等了一下，所有内容一起出现」。

软断句若在 12.5s 因短暂停顿触发：用户会先看到一次大约 12 秒音频的 final 倾倒，然后新句才重新开始出 partial。比 20 秒硬切好，但 **8–12 秒仍然没 live 字**，且这次 final 仍然偏长。

---

## 3. 已采用改法：分段提交，继续听（commit-and-roll）

### 3.1 方案

mlx-audio 没有增量编码器，做不到研究意义上的真流式。在现有约束下，让 **每次送进模型的音频始终短**（继续用约 8 秒上限），并且 **到期就提交，而不是停更**。

当当前句达到 `partial_max_audio_seconds`（8s）：

1. 立刻把当前这段当作一句 `final`（`reason=max_audio_window` 或优先 `soft` 切点）
2. 清空 `_utterance` / pre-roll，后续语音当作 **新一句**
3. 新句从短窗重新发 `partial`

当前默认切点：

- 句长达到 8s，且已有 ≥0.40s 静音 → 在静音处切（少切词）
- 否则在 8s **硬切**（连续说也不冻）
- **不要做音频重叠**：重叠会让下一句把上一句末尾再认一遍，注入重复

Swift 注入不用改：`on_final` 已提交 pending，下一条 `on_partial` 只在后面接着打。

与 `f11a20b` 软断句的关系：软断句可保留，作为「12s + 0.5s 静音」的 VAD 兜底。若 8s 就会 roll，单句很少再长到 12s。两者不冲突；**软断句不能替代本方案**。

明确不做：

- 删掉 8s 上限（全量反复跑，更卡，final 更晚）
- 滑动窗口拼前缀（要和已提交文字对账；失败会大段退格；句末仍可能对 20s 做一次 generate，把前半段再改一遍）
- 依赖 mlx-audio 增量 KV cache（当前 API 没有）

### 3.2 价值

- Live 字在长口述中持续出现，不再 8 秒后冻住
- 每次 `generate` 的音频 ≤8s，停嘴后的等待从「1.5s + 十几秒音频推理」变成「1.5s + 短尾推理」
- 已提交的字不会被句末那一次大 final 整段退格重打（听写比「演示用滑窗」更合适）
- 改动集中在 `PartialEngine`，与现有 IPC / 注入状态机同构

### 3.3 代价

- 硬切可能把一个词/音节切开（下一句开头或上一句结尾多/少一两个字）
- 每 8 秒边界有一次短推理；worker 单线程，这期间新音频进队列、画面可能顿几百毫秒到约 1–2 秒，但不会再冻住十几秒
- 长段口述变成多句 final，语篇上下文靠已有的「上一句 final → system_prompt」，不再对 20 秒整段做一次全局纠正
- 已更新原先的 `test_partial_stops_after_max_audio_window_but_final_still_emits`：到期应变为 final + 新句，而不是「停 partial、等后面一次 final」

### 3.4 时序（推荐实现后）

```text
连续说约 20s，中间没有明显停顿

0.0s      句 A 开始
0.6–8.0s  句 A 的 partial，行为与现在相同
≈8.0s     硬切：generate(句 A ≤8s) → on_final(A)
          队列里 8s 之后的块组成句 B（经过 0.20s 语音即可建句）
8.0s+     句 B 开始出 partial（短窗，又快了）
≈16.0s    同样提交句 B，开始句 C
停嘴      等 1.5s 句末静音 → generate(句 C 短尾) → on_final(C)
```

有短换气时（更好的切点）：

```text
0–8.0s    句 A partial
8.0s      到达滚动上限；若此时已有 0.40s+ 静音
          → 在静音处 final(A)，否则直接 max_audio_window final(A)
随后      句 B 继续 live
```

和现状对比（同一段 15s 不停顿口述）：

```text
现状
  0–8s   live
  8–15s  冻住
  15s    停嘴
  16.5s  静音够了，开始 generate(15s)
  ~18s   一条 final 倾倒 8s 之后的全部字

推荐
  0–8s   live
  ~8s    短 final，提交前 8s
  8–15s  继续 live
  15s    停嘴
  16.5s  generate(仅最后一段 <8s)
  ~17s   短 final，补最后一小段
```

### 3.5 落地范围

已改 Python 引擎与测试，未改 Swift：

1. `_process_active_utterance`：超过窗口时 `finalize` + 允许后续块新建 utterance，而不是 `continue` 空转
2. 切点：到 8s 后优先看 0.40s 静音，否则满 8s 硬切；不重叠音频
3. `final_metrics` 增加 `reason=max_audio_window`（短静音切可用现有 `soft_silence` 或新 reason，避免和 12s 软上限语义混用）
4. 修正 `AsrConfig` 注释：不是滑动窗口，是 partial 停更阈值 / 滚动提交阈值
5. 更新 P1-3 那条「超过窗口停 partial」的测试，补「连续语音滚动成两句、注入事件为 final 后新 partial」

### 3.6 实机反馈

2026-08-18 实机长口述反馈：

- 连续说到 10 秒、18 秒以上后，没有再出现持续卡顿或必须停顿才能继续出字。
- 整体 live 体验明显更流畅。
- 内容准确率未见明显下降。
- 这说明本改动主要改善实时性与可用性，不应被误记为“准确率显著提升”。

---

## 4. 结论

| 问题 | 长句后 live 停更，再一次性出字 |
|------|------------------------------|
| 最新分支 | **已修复并默认开启**；实机反馈为 10s/18s+ 长句不再连续卡顿 |
| 方案 | 分段提交、继续听 |
| 不推荐 | 删 8s 帽、滑窗拼字、幻想增量 API |

后续如果继续追求中文准确率，不应继续在本问题上堆规则；应转入 P2-1 评测闭环，用固定音频样本衡量 CER、术语命中率和延迟。
