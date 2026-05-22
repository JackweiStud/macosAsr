# macosAsr

[English](README.md) | **简体中文**

**macOS 菜单栏本地语音听写**：在任意 App 光标处 **边说边出字**，音频不出本机（Qwen3-ASR + MLX）。

规格文档：`docs/SDD/` · 开发进度：`docs/dev/PROGRESS.md`

---

## 核心卖点

- **本地推理**：Qwen3-ASR + MLX，音频不出本机。
- **说哪写哪**：识别结果直接写到当前 App 的光标处，不用复制、切换、再粘贴。
- **菜单栏常驻**：轻量 Swift 壳 + Python Daemon，适合开发者自建，不依赖 App Store。

> 当前版本通过菜单栏 **Start Live Dictation / Stop Live Dictation** 触发，打开就能直接试“边说边出字”。

---

## 适用对象

**面向会在 Mac 上 clone、构建、运行的开发者/高级用户**，不是「下载即用」的 App Store 产品。

**适合你如果：**

- 使用 **macOS 15+ / Apple Silicon**
- 希望 **本地** 听写，音频不离开机器
- 能接受 `./scripts/setup_env.sh` + `./scripts/build_macapp.sh` 自建流程

**不适合如果你：**

- 需要 Mac App Store 一键安装
- 使用 Intel Mac 或 macOS 14 及以下
- 不愿授予 **辅助功能**（将文字注入到光标处）

分发方式：**GitHub 开源 + 本机自建**（见 [LICENSE](LICENSE)）。

---

## 为什么不是别的方案

- **不是云端听写**：音频不上传第三方，隐私和离线可用性更稳。
- **不是录完再粘贴**：文字直接落到你正在编辑的 App，少一次复制/切换/粘贴。
- **不是黑箱产品**：你能自己构建、看日志、调语言和模型，而不是被固定流程绑死。

---

## 第三方许可

| 组件 | 用途 | 许可 / 说明 |
|------|------|-------------|
| **macosAsr 代码** | App + Daemon | [MIT](LICENSE) |
| **ASR 逻辑来源** | `asr/` 核心 | 衍生自 ASR-QWEN，见 [NOTICE](NOTICE) |
| **[mlx](https://github.com/ml-explore/mlx)** / **[mlx-audio](https://github.com/ml-explore/mlx-audio)** | 本地推理 | Apache-2.0（以其仓库为准） |
| **[Qwen3-ASR](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-8bit)** | 默认语音识别模型 | 首次运行从 Hugging Face 下载；遵守模型卡片与 Qwen 许可 |
| **numpy**, **sounddevice** | 音频与数值 | 各自上游许可（BSD / MIT） |
| **PortAudio**（系统可选依赖） | 麦克风后端 | 见 [portaudio.com](http://www.portaudio.com/) |

模型权重 **不会** 随仓库分发；首次启动需联网下载约 **3 GB**。默认模型：**`mlx-community/Qwen3-ASR-0.6B-8bit`**。

---

## 系统要求

| 项 | 要求 |
|----|------|
| 系统 | **macOS 15.0+**（Apple Silicon） |
| Python | **3.11+**（推荐 3.12；本地曾在 3.14 验证） |
| 硬件 | 建议 16GB 内存（0.6B 模型） |
| 工具 | Xcode **Command Line Tools**（`xcode-select --install`）— **不需要**完整 Xcode.app |
| 构建 | **`scripts/build_macapp.sh`**（`swiftc`）— 仓库内无 `.xcodeproj` |
| 可选 | [Homebrew](https://brew.sh)（安装 PortAudio） |

---

## 第一次使用（完整流程）

### 1. 克隆并进入目录

```bash
git clone https://github.com/<your-org>/macosAsr.git
cd macosAsr
```

### 2. 安装 Python 依赖

```bash
./scripts/setup_env.sh
```

会创建 `.venv/` 并安装 `requirements.txt` 中的固定版本：

- `mlx` / `mlx-audio` — 本地 ASR
- `numpy` / `sounddevice` — 音频采集

**若麦克风无数据**，安装 PortAudio：

```bash
brew install portaudio
```

### 3. 创建代码签名证书（一次性，避免 rebuild 后辅助功能失效）

```bash
./scripts/create_codesign_cert.sh
```

按提示输入 **Mac 登录密码**，设置钥匙串 ACL（仅一次）。

### 4. 构建菜单栏 App

```bash
./scripts/build_macapp.sh
```

期望输出：`Signed with: macosAsr Local`

> **仅需 Command Line Tools** — 不必安装 Xcode.app；仓库内也没有 `.xcodeproj`。

### 5. 启动 App

```bash
./scripts/launch_macapp.sh
```

菜单栏出现 **`⏳ ASR`** → 约 30 秒后变为 **`🎤 ASR`**（模型加载 + 噪声校准，期间保持安静 3 秒）。

> **无需** 手动运行 `python -m asr_daemon`，App 会自动启动。

### 6. 授权辅助功能（一次性）

1. **系统设置 → 隐私与安全性 → 辅助功能**
2. 找到 **macosAsrApp**，开关拨到 **ON（蓝色）**
3. 若无效：点 **「−」** 删除旧条目 → 再 `./scripts/launch_macapp.sh` → 重新 ON
4. 菜单栏 **🎤 ASR → Quit（⌘Q）** → 再 `./scripts/launch_macapp.sh`

### 7. Live 听写

1. 打开 **备忘录**（或你已验证过的 App），光标放空白处
2. 菜单栏 **🎤 ASR → Start Live Dictation**
3. 对着麦克风说话（中文或英文 — 在 **Settings…** 中选择语言）
4. **Stop Live Dictation** 结束

听写中菜单栏显示 **`🟢 Dictating…`**。

### 8.（可选）桌面快捷方式

若只用命令行启动，可跳过本节。

```bash
./scripts/install_desktop_shortcut.sh
```

会在 **`~/Desktop/macosAsr.app`** 创建启动器图标，双击效果等同 `./scripts/launch_macapp.sh`。

仓库路径写入 `~/Library/Application Support/macosAsr/repo_root`（不会写死在 Desktop 应用里）。**若移动了 clone 目录**，请在新路径下重新运行上述安装命令。

---

## 为何需要代码签名？

macOS 的 **辅助功能** 授权绑定在 App 的 **代码身份** 上：

| 签名方式 | 每次 `./scripts/build_macapp.sh` 之后 |
|----------|----------------------------------------|
| **Ad-hoc**（`codesign -`） | 签名 hash 变化 → 辅助功能常 **失效**，需重新授权 |
| **`macosAsr Local`**（推荐） | 身份稳定 → 开关通常 **可保留** |

第 3 步的 `create_codesign_cert.sh` 创建的是 **本机自签** 证书，用于开发自用，不是 Apple 开发者账号，也与 App Store 无关。跳过也可构建（回退 ad-hoc），但权限更容易反复失效。

---

## 启动方式（三选一）

| 方式 | 命令 / 操作 | 说明 |
|------|-------------|------|
| **命令行（推荐开发）** | `./scripts/launch_macapp.sh` | 自动设置 `MACOSASR_ROOT`，结束旧实例；无 daemon 时清理残留 socket |
| **桌面一键** | `./scripts/install_desktop_shortcut.sh` → 双击 **`~/Desktop/macosAsr.app`** | 路径写入 Application Support；移动 clone 后需重新安装 |
| **登录自启** | `./scripts/install_login_item.sh install` | 共用 `launch.sh`；移除：`uninstall` |

退出 App（菜单 **Quit ⌘Q**）时会 **同时关闭 asr_daemon**，释放模型内存。

### 桌面快捷方式说明

1. 在 clone 目录执行一次：`./scripts/install_desktop_shortcut.sh`
2. 桌面出现麦克风图标 **`macosAsr.app`**（启动包装器，不是完整 App 副本）
3. 实际通过 `~/Library/Application Support/macosAsr/launch.sh` 读取 `repo_root` 定位仓库
4. **换目录 clone 或移动文件夹后**：在新路径重新运行安装脚本

---

## 日常使用（3 步）

```bash
cd /path/to/macosAsr
./scripts/launch_macapp.sh
```

等 **`🎤 ASR`** → 光标放好 → **Start Live Dictation** → 说话 → **Stop**。

改代码后 rebuild：

```bash
./scripts/build_macapp.sh
./scripts/launch_macapp.sh
```

使用 `macosAsr Local` 签名后，**一般不需要**重复授权辅助功能。

### 高级：partial 刷新间隔

默认 **0.5 秒**（`asr/config.py`）。启动 daemon 前可覆盖：

```bash
export MACOSASR_PARTIAL_INTERVAL=0.8
./scripts/launch_macapp.sh
```

数值越小 live 感越强，GPU/注入开销越大。设置页不提供此项调整。

识别语言在 **Settings…**（中文 / English）中配置，保存在 `~/Library/Application Support/macosAsr/config.json`。

---

## 依赖清单

| 依赖 | 用途 | 安装方式 |
|------|------|----------|
| Python 3.11+ | ASR Daemon | 系统自带 / Homebrew |
| `.venv` + `requirements.txt` | Python 包 | `./scripts/setup_env.sh` |
| PortAudio | 麦克风采集 | `brew install portaudio` |
| Command Line Tools | 编译 Swift App | `xcode-select --install` |
| `macosAsr Local` 证书 | 稳定签名 | `./scripts/create_codesign_cert.sh` |
| MLX 模型 | 首次下载 ~3GB | 首次启动自动从 HuggingFace 拉取 |

Python 包见 [`requirements.txt`](requirements.txt)。

---

## 日志

| 文件 | 内容 |
|------|------|
| `log/macapp.log` | App：启动、daemon 状态、听写开始/结束、错误 |
| `log/daemon.log` | Daemon：模型加载、VAD 校准、session |

策略见 [`docs/dev/LOGGING.md`](docs/dev/LOGGING.md)。**不记录识别全文**。

排查：

```bash
tail -20 log/macapp.log
tail -20 log/daemon.log
```

---

## 常见问题

| 问题 | 处理 |
|------|------|
| 菜单栏无 🎤 ASR | 系统设置 → 控制中心 → 关闭菜单栏「自动隐藏」 |
| 辅助功能反复失效 | 确认 build 输出 `Signed with: macosAsr Local`；删旧条目重授权 |
| 一直 ⏳ ASR | 等 ~30s；看 `log/daemon.log` 是否模型加载失败 |
| Live 无文字 | 确认 `trusted=true`（macapp.log）；备忘录在前台再点 Start |
| codesign 卡住 | 运行 `./scripts/setup_codesign_acl.sh` |
| Quit 灰色无法退出 | 已修复：Quit 需指向 App 自身 action；请 rebuild 后重试 |
| 退出后 daemon 仍占内存 | 正常：Quit 会发 shutdown；若异常残留可 `pkill -f asr_daemon` |
| 桌面快捷方式移动仓库后失效 | 在新路径重新运行 `./scripts/install_desktop_shortcut.sh` |

---

## 开发

```bash
./scripts/test_p0c.sh           # Swift 编译 + 状态机自测
./scripts/ci_smoke.sh           # 本地 CI 冒烟（含 Python import）
./scripts/build_macapp.sh
```

MacApp 官方构建方式：**仅通过脚本 + swiftc**（无 Xcode 工程文件）。

- MacApp 细节：[`MacApp/README.md`](MacApp/README.md)
- 开发流程：[`docs/dev/LARF.md`](docs/dev/LARF.md)
