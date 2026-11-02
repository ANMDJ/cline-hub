# 更新日志（CHANGELOG）

> 按版本记录「用户能感知的变化」。开发过程（为什么改、踩了什么坑）在
> [`docs/status.md`](docs/status.md) §8，主动中断记录在
> [`docs/interruptions.md`](docs/interruptions.md)，单条设计决策在
> [`docs/decisions.md`](docs/decisions.md)。日期均为 +08。

## 2026-11-02 · Hub 0.1.0 / bridge 0.1.0

### 新增

- **读接口按设备隔离（P19，ADR-43）**：`device` token 只能读自己的会话 / 消息 / 命令 / hook，
  跨设备返回 `403 device_mismatch`；SSE 也只推自己的事件。`app` / `admin` 不传 `deviceId`
  仍是全量，单设备下行为不变。为 P3「多设备」铺路。
- 文档：`GET /api/v1/sessions` 补上 `cursor`（分页游标）与 `deviceId` 参数。
- 远程命令闭环：`pending → delivered → running → done/failed/cancelled`，
  领取用 `FOR UPDATE SKIP LOCKED`，多实例也不会重复执行。
- 命令进程身份：`pid` / `pidStartedAt` / `runner` 回写 Hub（迁移 006）；本机登记 +
  `npm run ps` 按「pid + 启动时间」双校验（Windows 会复用 PID）。
- 手机取消命令：执行中先置 `cancelling`，bridge 按 commandId 杀进程树后回写 `cancelled`
  （迁移 007 / 008）。
- 命令并发池：`commands.concurrency`（1–8，默认 1），同一个 workspace 强制串行。
- `cline --json` 结构化输出：干净终稿 / 失败原因 / 用量。
- 优雅停止与空闲重启：`npm run stop` / `restart` / `restart:idle`——先回写执行中的命令，
  再杀进程树（ADR-36 / 39）。
- 孤儿回收：Hub 上 `running` 但本机已无对应进程 → 回写 `failed: orphaned`，不盲杀。
- 会话消息上限 2000 → 20000 字（迁移 004）、`ask_question` 选项（迁移 005）、
  列表预览在服务端洗成纯文本平面。
- App 自更新：`GET /api/v1/app/latest` 清单 + Caddy 静态 APK 出口。

### 修复

- 手机发 `act` 却按 `plan` 执行：bridge 用 `CLINE_GLOBAL_SETTINGS_PATH` 钉死模式。
- 反代缓冲导致 SSE 事件延迟：Caddy 加 `flush_interval -1`。
- 命令卡「执行中」：bridge 重启后的启动对账 + 每 60 秒 `reconcile()`。

## App 1.1.4 · 2026-11-02

- 新增：命令详情可以「取消命令」——排队中的立即取消，执行中的由 bridge 停掉进程。
- 新增：会话正文与结果按 Markdown 渲染（标题 / 列表 / 代码块 / 表格），命令输出仍保持终端原文。
- 新增：Windows 端支持命令并发执行（不同工作目录并行，同一目录仍串行）。
- 优化：命令状态多一档「取消中」，取消后不会又变回「已完成」。

## App 1.1.3 · 2026-11-02

- 新增：有新版本时可以直接「打开下载页」，用系统浏览器下载 APK。
- 修复：命令一直显示「执行中」——bridge 主动重启前会先把执行中的命令标记为中断并说明原因。

## App 1.1.2 · 2026-11-02

- 新增：远程命令完成 / 失败时弹系统通知（可在设置里关掉，Android 13+ 需授权）。
- 新增：会话结束 / 失败时弹系统通知。
- 修复：bridge 重启后会把没有进程接管的命令标记为失败并说明原因。
- 优化：命令详情显示 pid / runner / 启动时间，可复制排查命令。

## App 1.1.1 · 2026-11-02

- 修复：会话列表预览显示成 Markdown 源码（## / 代码围栏 / 表格竖线）。
- 修复：命令输出带终端颜色码，卡片和详情看起来像乱码；展示与复制都改为纯文本。

## App 1.1.0 · 2026-11-02

- 修复：手机发 ACT 却按 PLAN 执行（bridge 用 `CLINE_GLOBAL_SETTINGS_PATH` 钉死模式）。
- 修复：PLAN / ACT 选中态配色看不清。
- 会话消息上限 2000 → 20000 字，长回复不再被截断；支持最近 60 个会话回填。
- 新增：长文本折叠 + 「展开全文」二级页、消息级复制、整段对话复制。
- 新增：会话里的「选择题」可直接点选（作为新命令下发）。
- 新增：版本与更新日志、检查更新。

## App 1.0.0 · 2026-10-31

- 会话 / 命令 / 动态三页 + SSE。
- 会话详情逐条消息流、概览弹层、继续对话。
