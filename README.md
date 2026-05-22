# macosAsr

macOS 菜单栏本地语音听写：在任意 App 光标处 **边说边出字**，数据不出本机（Qwen3-ASR + MLX）。

规格文档：`docs/SDD/` · 开发进度：`docs/dev/PROGRESS.md`

---

## 系统要求

| 项 | 要求 |
|----|------|
| 系统 | **macOS 15.0+**（Apple Silicon） |
| 硬件 | 建议 16GB 内存（0.6B 模型） |
| 工具 | Xcode **Command Line Tools**（`xcode-select --install`） |
| 可选 | [Homebrew](https://brew.sh)（安装 PortAudio） |

---

## 第一次使用（完整流程）

### 1. 克隆并进入目录

```bash
git clone <你的仓库地址> macosAsr
cd macosAsr
```

### 2. 安装 Python 依赖

```bash
./scripts/setup_env.sh
```

会创建 `.venv/` 并安装 `requirements.txt`：

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
3. 对着麦克风说中文
4. **Stop Live Dictation** 结束

听写中菜单栏显示 **`🟢 状态：听写中…`**。

---

## 启动方式（三选一）

| 方式 | 命令 / 操作 | 说明 |
|------|-------------|------|
| **命令行（推荐开发）** | `./scripts/launch_macapp.sh` | 自动设置 `MACOSASR_ROOT`，结束旧实例；无 daemon 时清理残留 socket |
| **桌面一键** | `./scripts/install_desktop_shortcut.sh` → 双击桌面 **macosAsr.app** | 绿色麦克风图标；首次需 build |
| **登录自启** | `./scripts/install_login_item.sh install` | 用户登录 macOS 后自动启动；移除：`uninstall` |

退出 App（菜单 **Quit ⌘Q**）时会 **同时关闭 asr_daemon**，释放模型内存。

---

## 日常使用（3 步）

```bash
cd /Users/jackwl/Code/macosAsr
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

默认 **1.0 秒**（`asr/config.py`）。启动 daemon 前可覆盖：

```bash
export MACOSASR_PARTIAL_INTERVAL=0.8
./scripts/launch_macapp.sh
```

数值越小 live 感越强，GPU/注入开销越大。

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

---

## 开发

```bash
./scripts/test_p0c.sh           # 编译 + 状态机自测
./scripts/build_macapp.sh
MacApp/README.md                # MacApp 细节
docs/dev/LARF.md                # 开发流程
```
