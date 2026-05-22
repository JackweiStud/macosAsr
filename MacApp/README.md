# MacApp — 菜单栏听写

Menu Bar App：**Live 听写**（接 `asr_daemon`）+ **Mock 注入测试**（开发验收）。

## 构建与启动

```bash
cd /path/to/macosAsr
./scripts/create_codesign_cert.sh   # 首次
./scripts/build_macapp.sh
./scripts/launch_macapp.sh
```

## 菜单栏状态

| 显示 | 含义 |
|------|------|
| `⏳ ASR` | Daemon 加载模型 / 校准中 |
| `🎤 ASR` | 就绪，可 Start Live Dictation |
| `状态：听写中…` | 听写中 |
| `⚠️ ASR` | 错误（见 `log/macapp.log`） |

## Live 听写

1. 辅助功能已授权 **macosAsrApp**
2. 目标 App（备忘录等）光标就位
3. **Start Live Dictation** → 说话 → **Stop Live Dictation**

App 启动时会自动 `warmUp` daemon，**无需**手动 `python -m asr_daemon`。

## Mock 测试（P0c）

菜单 **Run Mock Injection Test…** — 期望备忘录光标处：`你好，世界。`

## 日志

- `log/macapp.log` — 本 App
- `log/daemon.log` — ASR 后端

## 无 Xcode.app 构建

使用 `scripts/build_macapp.sh`（swiftc + bundle）。可选：`open MacApp/macosAsrApp.xcodeproj`
