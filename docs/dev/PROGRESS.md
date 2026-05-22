# macosAsr 开发进度（Living Log）

> 规格基线：**SDD v0.1.2**（2026-05-21）  
> MVP 触发：**菜单 Start/Stop Live**（Fn+V PTT 暂缓 P1）  
> 工作流：[LARF.md](./LARF.md)

## Current phase

**P0 完成** — Mock 注入 **PASS**；Live 听写 **PASS**（菜单触发）；本地化 polish ✅（菜单已移除 Mock 注入测试入口）

## Next actions（P1 候选）

1. Fn+V PTT 热键
2. 设置页（快捷键、语言、partial 间隔 GUI）
3. 三步权限 Onboarding
4. Daemon 崩溃自动恢复

---

## 里程碑

| 阶段 | 状态 | 说明 |
|------|------|------|
| P0a ASR + Daemon | ✅ | `asr/` + `asr_daemon` IPC |
| P0b IPC 门禁 | ✅ | T-02/T-03 PASS（人声） |
| P0c Mock 注入 | ✅ | 备忘录「你好，世界。」 |
| P0d Live 听写 | ✅ | 菜单 Start/Stop + 多句 final |
| 稳定签名 + warmUp | ✅ | `macosAsr Local`、四态菜单栏 |
| 本地化 polish | ✅ | 桌面/登录启动、Quit 关 daemon、partial 1.0s |

---

## 日常使用

```bash
./scripts/launch_macapp.sh              # 命令行
./scripts/install_desktop_shortcut.sh   # 桌面图标
./scripts/install_login_item.sh install # 登录自启
```

Quit（⌘Q）关闭 App **并** shutdown daemon。

---

## LARF 周期历史（摘要）

| 日期 | 阶段 | 结果 |
|------|------|------|
| 2026-05-21 | P0a+P0b | IPC ping PASS；session-test 需人声 |
| 2026-05-22 | P0b 复测 | T-02/T-03 PASS；MLX worker 线程 fix |
| 2026-05-22 | P0c | Mock 注入 PASS |
| 2026-05-22 | P0d | Live 听写 PASS |
| 2026-05-22 | Top1+2 | 稳定签名、auto warmUp、菜单四态 |
| 2026-05-22 | polish | 日志精简、README、Quit fix、启动方式 |

详细 Reflect 见下方历史条目（保留）。

### 周期 #1–#4

见 git 历史及 `docs/dev/AGENT_HANDOFF.md` 归档说明。

**P0c GUI PASS（2026-05-22）**：备忘录 Mock「你好，世界。」；`trusted=true`。

**P0d Live PASS（2026-05-22）**：菜单 Start/Stop；多句 VAD 断句 + final 注入正常。

---

## 默认参数（当前实现）

| 参数 | SDD 默认 | 当前 |
|------|----------|------|
| partial_interval | 0.25s | **1.0s**（`MACOSASR_PARTIAL_INTERVAL` 可覆盖） |
| 触发方式 | Fn+V PTT | 菜单 Start/Stop |
| Daemon 生命周期 | 常驻 | App 启动 warm；**Quit 时 shutdown** |
