# 运行时日志约定

> 对齐 SDD §7、§11 与用户要求：**所有 Python 运行时日志写入项目 `log/`**（目录 gitignore，保留 `log/.gitkeep`）。

## 日志文件

| 文件 | 组件 | 说明 |
|------|------|------|
| `log/daemon.log` | `asr_daemon` | 默认；`python -m asr_daemon` 经 `setup_tee` 镜像 stdout/stderr |
| `log/asr.log` | `asr` 库 / 测试 | 预留；独立脚本可 `--log-file log/asr.log` |
| `log/macapp.log` | `MacApp` (Swift) | P0c+；`AppLogger` 追加写入 |

## 启用方式

Daemon 入口（`asr_daemon/__main__.py`）：

```python
from asr.run_utils import DEFAULT_DAEMON_LOG, setup_tee
setup_tee(DEFAULT_DAEMON_LOG)
```

路径常量见 `asr/run_utils.py`：

- `DEFAULT_DAEMON_LOG` → `<repo>/log/daemon.log`
- `DEFAULT_ASR_LOG` → `<repo>/log/asr.log`

覆盖路径：

```bash
python -m asr_daemon --log-file log/daemon.debug.log
```

## 内容策略（SDD §9）

- **默认 INFO**：启动、校准、session、socket；**不记录完整 transcript**
- DEBUG（`-v`）：VAD 阈值、utterance 边界；仍避免整句刷屏
- 识别结果仅通过 **IPC JSON 事件** 发给客户端，而非写入日志全文

## Git

`.gitignore`：

```
log/*
!log/.gitkeep
```

本地日志不提交；协作者各自 `log/` 目录。

## 与 LARF Reflect 的关系

Reflect 阶段失败时，在 `PROGRESS.md` 附：

- 复现命令
- `tail -n 50 log/daemon.log` 中的 **错误行**（勿贴长 transcript）
