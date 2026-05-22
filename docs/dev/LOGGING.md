# 运行时日志约定

> 对齐 SDD §11：**不记录识别全文**；默认只保留关键生命周期与错误。

## 日志文件

| 文件 | 组件 | 说明 |
|------|------|------|
| `log/daemon.log` | `asr_daemon` | 模型加载、VAD 校准、session 起止 |
| `log/macapp.log` | `MacApp` | 启动、daemon 状态机、听写起止、错误 |
| `log/asr.log` | 预留 | 独立脚本可选 |

## macapp.log 记什么

| 级别 | 示例 |
|------|------|
| INFO | `launch trusted=true` · `daemon_state loading -> ready` · `live_dictation_started` · `final len=12` |
| WARN | 辅助功能未授权 |
| ERROR | daemon 启动失败、IPC 错误 |

**不记录**：每次 partial 注入细节、每次 App 激活、socket 连接、pending 状态机内部步骤。

## daemon.log 记什么

| 级别 | 示例 |
|------|------|
| INFO | `daemon listening` · `loading model` · `VAD threshold=…` · `session_started/stopped` · `listening=True/False` |
| DEBUG | `-v` 时 utterance 边界、client 连接 |
| 已过滤 | httpx 请求、HF 下载进度条、tqdm 行 |

启用 DEBUG：`python -m asr_daemon -v`

## Git

```
log/*
!log/.gitkeep
```

本地日志不提交。
