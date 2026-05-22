# MacApp — 菜单栏听写

Menu Bar App：**Live 听写**（接 `asr_daemon`）。

## 构建与启动

```bash
cd /path/to/macosAsr
./scripts/create_codesign_cert.sh   # 首次
./scripts/build_macapp.sh
./scripts/launch_macapp.sh          # 命令行启动
```

**其他启动方式：**

```bash
./scripts/install_desktop_shortcut.sh   # 桌面 macosAsr.app
./scripts/install_login_item.sh install # 登录自启
```

退出：**菜单栏 🎤 ASR → Quit（⌘Q）** — 会关闭 App 与 asr_daemon。

## 菜单栏状态

| 显示 | 含义 |
|------|------|
| `⏳ ASR` | Daemon 加载模型 / 校准中 |
| `🎤 ASR` | 就绪，可 Start Live Dictation |
| `🟢 状态：听写中…` | 听写中 |
| `⚠️ ASR` | 错误（见 `log/macapp.log`） |

## Live 听写

1. 辅助功能已授权 **macosAsrApp**
2. 目标 App（备忘录等）光标就位
3. **Start Live Dictation** → 说话 → **Stop Live Dictation**

App 启动时会自动 `warmUp` daemon，**无需**手动 `python -m asr_daemon`。

## 调优

| 项 | 默认 | 覆盖 |
|----|------|------|
| partial 间隔 | 1.0s | 环境变量 `MACOSASR_PARTIAL_INTERVAL` |
| 注入按键延迟 | 0.4ms/键 | `TextInjector.swift` |

## 日志

- `log/macapp.log` — 本 App
- `log/daemon.log` — ASR 后端

## 无 Xcode.app 构建

使用 `scripts/build_macapp.sh`（swiftc + bundle）。可选：`open MacApp/macosAsrApp.xcodeproj`
