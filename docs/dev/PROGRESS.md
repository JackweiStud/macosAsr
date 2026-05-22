# macosAsr 开发进度（Living Log）

> 规格基线：**SDD v0.1.2**（2026-05-21）  
> 产品默认：**Fn + V** PTT（见 PRD §4.2.2）  
> 工作流：[LARF.md](./LARF.md)

## Current phase

**P0b — PASS**（T-02/T-03 人声 session-test 已通过，2026-05-22）

## Next actions

1. 进入 **P0c**：Swift TextInjector mock（mock partial → 备忘录光标）
2. 启动 daemon 勿再用 `>> log/daemon.log`（进程内 `setup_tee` 已写同一文件，会重复落盘）

---

## LARF 周期历史

| 日期 | 阶段 | Learn | Act | Reflect | Fix | 测试 |
|------|------|-------|-----|---------|-----|------|
| 2026-05-21 | P0a+P0b | 读 TDD §3–§5、§10.3、§11；确认 IPC JSON-lines、partial-first、log/ 落盘 | 复制 `asr/*`；实现 `asr_daemon`（server/session/cli）；`setup_env.sh`、`NOTICE`、dev 文档 | 见下方 **周期 #1 Reflect** | 无 | **PASS**（help、IPC ping）；**BLOCKED**（MLX session-test） |
| 2026-05-22 | P0b | 读 MLX 线程错误；重启 daemon（worker 线程 load 修复） | 人声 session-test 8s | 见 **周期 #3 Reflect** | MLX Stream 跨线程 | **PASS** T-02/T-03 |

### 周期 #1 Reflect（2026-05-21）

**命令：**

```bash
cd /Users/jackwl/Code/macosAsr
chmod +x scripts/setup_env.sh
./scripts/setup_env.sh
source .venv/bin/activate
export PYTHONPATH="$(pwd):${PYTHONPATH:-}"

python -m asr_daemon --help
python -m asr_daemon.cli_client --help
```

**结果：**

| 测试项 | 结果 | 说明 |
|--------|------|------|
| `python -m asr_daemon --help` | **PASS** | exit 0，打印 argparse 帮助 |
| `python -m asr_daemon.cli_client --help` | **PASS** | exit 0 |
| `asr` 包导入 | **PASS** | `from asr.partial_engine import PartialEngine` |
| `cli_client --ping`（`--skip-model` daemon） | **PASS** | 返回 `pong`，`model_loaded: false`；日志见 `log/daemon.log` |
| `cli_client --ping`（daemon 未起） | **预期失败** | `socket not found`（exit 1） |
| `./scripts/setup_env.sh` | **未执行** | 需本地安装 `mlx` / `mlx-audio` |
| `cli_client --session-test`（完整模型） | **BLOCKED** | 依赖 venv + 麦克风 + 模型下载 |

**IPC ping（已通过，`--skip-model`）：**

```json
{"protocol": 1, "type": "pong", "model_loaded": false, "calibrated": false}
```

**BLOCKED 详情（完整 P0b session-test）：** 未安装 `mlx_audio`；需 `./scripts/setup_env.sh` 后启动完整 daemon。



### 周期 #2 Reflect（2026-05-22）

**Learn：** `./scripts/setup_env.sh` 已成功（`.venv`、`mlx_audio` 可导入）；`log/daemon.log` 有模型加载与校准记录；T-02/T-03 定义见 SDD §10.2。

**Act 命令：**

```bash
cd /Users/jackwl/Code/macosAsr
source .venv/bin/activate
export PYTHONPATH="$(pwd):${PYTHONPATH:-}"
pkill -f "python.*asr_daemon"   # 若存在多实例/旧 --skip-model
python -m asr_daemon &
# 等待 ping 返回 model_loaded + calibrated（约 10–30s）
python -m asr_daemon.cli_client --ping
python -m asr_daemon.cli_client --session-test --duration 5
```

**环境检查：**

| 项 | 结果 |
|----|------|
| `./scripts/setup_env.sh` / `.venv` | **PASS** |
| `import mlx_audio` | **PASS** |
| `log/daemon.log` 运行时条目 | **PASS**（listening/session/client） |
| 麦克风采集（2s RMS 监测） | **PASS**（有数据；安静环境 max RMS ≈ 0.003） |
| VAD 阈值（校准后） | ≈ **0.008**（高于环境 RMS，需人声触发） |

**IPC ping（完整 daemon）：**

```json
{
  "protocol": 1,
  "type": "pong",
  "model_loaded": true,
  "calibrated": true
}
```

**session-test（安静环境，未对人说话）：**

```
{"protocol": 1, "type": "session_started", "session_id": "s-5647a6e7"}
{"protocol": 1, "type": "session_stopped", "session_id": "s-5647a6e7"}
--- summary: partials=0 finals/filtered=0 T-02=FAIL T-03=FAIL ---
```

| 门禁 | 结果 | 说明 |
|------|------|------|
| T-02（5s 内 ≥1 partial） | **FAIL** | 无 utterance 启动；非代码崩溃 |
| T-03（stop 后 final/filtered） | **FAIL** | `flush_on_stop` 无活跃 utterance 时不产出 |
| `cli_client --ping` | **PASS** | |
| P0b 总门禁 | **未 PASS** | 硬门禁：禁止 Swift 联调 |

**Fix（本周期）：** `cli_client --session-test` 输出 SDD T-02/T-03 PASS/FAIL；无声时 stderr hint。根因判定为 **测试条件（需人声）**，非 IPC/引擎崩溃。

**复测建议：** session 的 5s 内对着麦克风说完整中文句；期望 partial → stop 后 final/filtered。

### 周期 #3 Reflect（2026-05-22）

**Fix：** `partial_engine` 模型加载与 ASR 推理统一在 worker 线程（修复 `Stream(gpu, 1) in current thread`）。

**session-test（人声，8s）：**

| 门禁 | 结果 |
|------|------|
| T-02 | **PASS**（8 个 partial） |
| T-03 | **PASS**（1 个 final） |
| P0b 总门禁 | **PASS** |

样例 final：`有听到我声音吗？听到请回答，听到请回答。`

**下一里程碑：P0c** Swift 注入 mock（SDD 硬门禁已满足）。


```bash
source .venv/bin/activate
export PYTHONPATH="$(pwd):${PYTHONPATH:-}"
python -m asr_daemon &
sleep 30   # 等待模型加载 + 噪声校准
python -m asr_daemon.cli_client --ping
python -m asr_daemon.cli_client --session-test --duration 5
```

---

## 里程碑备注

- **2026-05-21**：按 SDD v0.1.2 启动实现；LARF 多 Agent 文档与 `log/` 基础设施就绪。
- 默认热键：**Fn + V**（MVP PTT，Swift 侧 P0d 实现）。
