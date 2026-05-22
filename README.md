# macosAsr

macOS 本地语音听写：Swift 热键 + Python ASR Daemon（规格见 `docs/SDD/`）。

## 快速开始（P0）

```bash
./scripts/setup_env.sh
source .venv/bin/activate
export PYTHONPATH="$(pwd):${PYTHONPATH:-}"

python -m asr_daemon --help
python -m asr_daemon          # 加载模型并监听 run/macosasr.sock
python -m asr_daemon.cli_client --ping
```

开发流程与进度：`docs/dev/`。
