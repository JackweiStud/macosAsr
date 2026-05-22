# Agent Handoff 模板

> 复制本节到新的 handoff 条目，或覆盖下方「当前交接」块。

---

## 当前交接

**日期**：2026-05-22  
**From**：Worker（LARF 周期 #2）  
**To**：下一 Worker（P0b 人声复测 → P0c）

### Context

- 仓库：`/Users/jackwl/Code/macosAsr`
- SDD：**v0.1.2**；默认热键 **Fn+V**
- Python：`asr/` + `asr_daemon/`；IPC：`run/macosasr.sock`，JSON-lines `protocol:1`
- 日志：`log/daemon.log`（`python -m asr_daemon` 内建 `setup_tee`；**不要**再 shell 重定向到同一文件）

### Done

- [x] LARF 周期 #1：`--help`、`--skip-model` ping
- [x] `./scripts/setup_env.sh` 已执行；`.venv` + `mlx_audio` 可用
- [x] 完整 daemon：`cli_client --ping` → `model_loaded: true`, `calibrated: true`
- [x] LARF 周期 #2 Reflect 写入 `PROGRESS.md`
- [x] `cli_client --session-test` 显式 T-02/T-03 与无声 hint

### Blocked

- [ ] P0b 硬门禁：`--session-test` T-02/T-03（本环境安静未对人说话 → FAIL；需本地人声复测）

### Next

1. 单实例 daemon：`pkill -f "python.*asr_daemon"` 后 `python -m asr_daemon`，等校准完成
2. 对着麦克风说话跑 `cli_client --session-test --duration 5` → T-02/T-03 **PASS** 后开 **P0c**
3. P0c：Swift TextInjector mock（退格重插）

### Commands

```bash
cd /Users/jackwl/Code/macosAsr
source .venv/bin/activate
export PYTHONPATH="$(pwd):${PYTHONPATH:-}"
python -m asr_daemon &
python -m asr_daemon.cli_client --ping
python -m asr_daemon.cli_client --session-test --duration 5
```

---

## 模板（复制用）

```markdown
**日期**：YYYY-MM-DD
**From**：
**To**：

### Context
- 分支 / 阶段：
- 相关 SDD 章节：

### Done
- [ ]

### Blocked
- [ ] （错误信息、路径）

### Next
1.

### Commands
\`\`\`bash
\`\`\`
```
