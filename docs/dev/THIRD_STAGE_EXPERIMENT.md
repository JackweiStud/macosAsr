# 第三阶段实验：VAD、延迟、停止安全

Branch: `codex/asr-vad-latency-sequencing`

这个分支是体验分支，还不是主干合并候选。它针对 3 个用户可感知问题：

1. VAD 把背景噪声误判为持续说话，导致 final 片段过长。
2. 没有可量化的 ASR partial/final 延迟数据。
3. Stop 之后时序不安全，用户开始编辑后，晚到的 final 还可能覆盖输入。

## 改了什么

- VAD 现在在一个正在进行的 utterance 内，会额外做相对静音判断。如果背景噪声仍高于绝对阈值，但明显低于最近说话峰值，也可以算作静音，从而结束这句话。
- `daemon.log` 现在会输出隐私安全的指标：
  - `utterance_started`
  - `partial_metrics`
  - `final_metrics`
- Stop 现在会进入 `stoppingAwaitingFinal` 状态。如果 daemon 还没发出 `session_stopped`，用户就先打字或点击，应用会清掉待处理的 ASR 文本，并丢弃晚到的 final，而不是去改写用户新输入的内容。

日志只包含长度、耗时和原因，不包含转写文本。

## 怎么测试

运行这个分支的构建：

```bash
open --env MACOSASR_ROOT=/Users/jackwl/Code/macosAsr "/Users/jackwl/Code/macosAsr/MacApp/build/macosAsrApp.app"
```

### 测试 1：VAD 断句

1. 按 `⌥Z` 开始听写。
2. 说一句短句。
3. 停顿大约 2 秒。
4. 再说第二句短句。
5. 再按 `⌥Z` 停止。

预期变化：final 更容易按短块到达，而不是两句被合成一大段。

Check:

```bash
tail -n 80 log/daemon.log | rg "utterance_started|final_metrics"
```

看这些信号：

- 独立句子会对应更多 `final_metrics` 行。
- 每个 final 的 `utterance_seconds` 更短。
- 普通短句出现超长 `final_len` 的情况更少。

### 测试 2：延迟指标

说一段 10 到 20 秒的混合长句，然后停止。

Check:

```bash
tail -n 120 log/daemon.log | rg "partial_metrics|final_metrics"
```

看这些信号：

- `first_partial_ms` 表示第一段可见文本出来用了多久。
- `partial_ms` 表示实时刷新是否开始变贵。
- `final_ms` 表示 final 修正用了多久。

### 测试 3：Stop 后再编辑

1. 开始听写。
2. 说一句足够长、能产出 partial 的句子。
3. 按 `⌥Z` 停止。
4. 在 final 到来前，立刻输入几个字符，或者点击别处。

预期变化：晚到的 final 不应该回退删除或改写你的手动编辑。

Check:

```bash
tail -n 80 log/macapp.log | rg "late_final|injection_pending"
```

看这些信号：

- `late_final_will_be_dropped_after_user_input`
- `late_final_dropped_after_user_input len=...`

## 验证

这个分支已经跑过的自动检查：

```bash
python3 -m unittest discover -s tests
./scripts/test_p0c.sh
./scripts/ci_smoke.sh
./scripts/build_macapp.sh
git diff --check
```
