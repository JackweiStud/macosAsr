# macosAsr — SDD 文档索引

> **开发方式**：Specification-Driven Development（规格驱动开发）  
> **原则**：先定规格、再实现。  
> **注意**：SDD 为设计基线；**实现细节以根目录 README 与代码为准**（如 partial 0.5s、无 xcodeproj、设置页语言等）。

| 文档 | 说明 | 状态 |
|------|------|------|
| [01-需求规格说明书（SRS）](./01-需求规格说明书-SRS.md) | 功能/非功能需求、约束、验收标准 | Draft v0.1 |
| [02-PRD 产品需求文档](./02-PRD产品需求文档.md) | 产品定位、用户故事、交互、里程碑 | Draft v0.1 |
| [03-技术方案与架构设计](./03-技术方案与架构设计.md) | 架构、模块、协议、状态机、部署 | Draft v0.1 |

## 开发文档（LARF 工作流）

实现进度与多 Agent 协作见 [`docs/dev/`](../dev/)：

| 文档 | 说明 |
|------|------|
| [LARF.md](../dev/LARF.md) | Learn → Act → Reflect → Fix 循环与 SDD 门禁 |
| [PROGRESS.md](../dev/PROGRESS.md) | 活进度日志与测试结论 |
| [archive/AGENT_HANDOFF.md](../dev/archive/AGENT_HANDOFF.md) | Agent 交接（已归档） |
| [LOGGING.md](../dev/LOGGING.md) | `log/` 目录与 tee 约定 |

## 修订记录

| 版本 | 日期 | 说明 |
|------|------|------|
| v0.1 | 2026-05-21 | 初稿：基于需求澄清与 ASR-QWEN 能力评估 |
| v0.1.2 | 2026-05-21 | 默认快捷键：`Fn + V` PTT 优先；补充 Fn 系统约束 |

## 术语

| 术语 | 含义 |
|------|------|
| PTT | Push-to-Talk，按住快捷键说话 |
| partial | ASR 说话过程中的中间识别结果 |
| final | 句末 `generate()` 提交的校正结果 |
| Daemon | 常驻 Python ASR 进程 |
| 注入 | 向前台 App 光标处模拟输入文字 |
