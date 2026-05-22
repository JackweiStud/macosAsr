# MacApp — P0c/P0d

Menu Bar 应用：**Mock 注入** + **Live 听写（接 asr_daemon）**。

## 快速开始（无需 Xcode.app）

```bash
cd /Users/jackwl/Code/macosAsr
./scripts/test_p0c.sh          # 自动化：编译 + 状态机
./scripts/build_macapp.sh      # 打包 .app
open MacApp/build/macosAsrApp.app
```

## 首次运行

1. **系统设置 → 辅助功能** — 勾选 **macosAsrApp**
2. 打开 **备忘录**，光标放在正文
3. 菜单栏麦克风 → **Start Live Dictation…** → 开始 → 对着麦克风说话
4. **Stop Live Dictation** 结束

App 会自动 spawn `python -m asr_daemon`（需已 `./scripts/setup_env.sh`）。

## Mock 测试（P0c）

菜单 **Run Mock Injection Test…** — 期望 final：`你好，世界。`

## 日志

- `log/macapp.log` — App 运行时
- `log/daemon.log` — ASR Daemon

环境变量 `MACOSASR_ROOT` 指向仓库根（build 脚本已内置）。

## Xcode（可选）

```bash
open MacApp/macosAsrApp.xcodeproj
```

Scheme 已设 `MACOSASR_ROOT=/Users/jackwl/Code/macosAsr`。
