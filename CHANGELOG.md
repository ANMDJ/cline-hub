# 更新日志（CHANGELOG）

> 按版本记录「用户能感知的变化」。开发过程（为什么改、踩了什么坑）在
> [`docs/status.md`](docs/status.md) §8，主动中断记录在
> [`docs/interruptions.md`](docs/interruptions.md)，单条设计决策在
> [`docs/decisions.md`](docs/decisions.md)。日期均为 +08。

## 2026-11-04 · App 1.3.2+15 / Hub 0.1.0（P40 / P41 / P43 / P50）

### PLAN / ACT 挪进输入条（P50，ADR-66）

- **模式开关和输入框同一行**：原来 PLAN / ACT 单独占输入框上方一行，现在挪到「+」左侧、
  与输入框和发送键齐平，聊天区多出一行；风险提示改成长按可见。
- 下发面板保持原样（PLAN / ACT / YOLO 三段 + 每种模式的说明，塞进一行会挤没输入区）。

### 实时连接的凭据不再进日志（P41，ADR-64）

- **SSE 改用一次性票据**：App 先 `POST /api/v1/sse-ticket` 换一张 `clt_…`（60 秒有效、
  用掉即作废），再用 `?ticket=` 连接；长期 token 不再出现在 URL、Caddy 访问日志、
  抓包或崩溃栈里。
- **兼容**：Hub 还没升级（没有该接口）时自动退回 `?token=`，连接不受影响；
  旧版 APK 也仍可用 token 连。

### 安全加固（P40 / P43，ADR-63 / ADR-65）

- **`X-Forwarded-For` 只认最后一段**：不再采信调用方自带的首段；Caddyfile 里两个 hub 站点
  显式 `header_up X-Forwarded-For {remote_host}`，`HUB_ALLOW_IPS` 与限流按真实 IP 生效
  （线上实测：伪造 `X-Forwarded-For: 1.2.3.4` 时 Hub 记录仍是真实 IP）。
- **SSE 纵深防御**：单 token 最多 8 条连接（超了踢最旧）、600 秒无写入断开、
  带 Origin 的跨源请求按 `HUB_SSE_ALLOWED_ORIGINS` 白名单拦截（不带 Origin 的 App / bridge 不受影响）。

### 配套

- 新增 `server/src/ticket.js`、`server/test/net.test.mjs`、`server/test/sse.test.mjs`；
  `docs/api.md` 补换票契约与错误码，`deploy/Caddyfile` / `docs/self-host.md` 同步。
- 验证：server `node --test` **81**（新增 13）、`flutter analyze` 0 issue、
  `flutter test` **107 通过 / 5 跳过**；线上 `GET /events?ticket=` 收到 `: connected`、
  同一张票重放 **401**。

## 2026-11-04 · App 1.3.1+14 / Hub 0.1.0（P49）

### 「未执行」和「失败」分开

- **bridge 在执行前就拒绝时，手机上不再只显示「失败」**：目录不存在 / 没指定、模式不在
  `allowModes`、目录不在白名单、`template` 为空、附件下载失败 → 命令卡片与详情用**警示色**
  显示「未执行」并写出具体原因；通知标题是「命令未执行」，不会让人去翻根本不存在的输出。
- **新增两个字段**（migration 011）：`commands.rejected_before_start` / `rejected_reason`；
  命令对象多 `rejectedBeforeStart` / `rejectedReason`，状态仍是 `failed`，
  老客户端忽略未知字段即可，Hub 与 App 可以分开升级。
- **明确不设默认目录**：`commands.defaultWorkspace` 保持空；命令必须自带真实存在的目录，
  留空会被直接拒绝（不再静默落到某个目录）。

### 配套

- `docs/api.md` 补 PATCH 契约与五个原因码；`bridge/README.md` 新增「执行前拒绝（P49）」；
  ADR-62。
- 验证：bridge `node --test` **65**、server `npm test` **68**、`flutter analyze` 0 issue、
  `flutter test` **103 通过 / 5 跳过**。

## 2026-11-04 · App 1.3.0+13 / Hub 0.1.0（P42 / P46 / P47）

### 输入区改版（P46，ADR-59）

- **发消息 / 发文件改成微信式输入条**：左侧「+」就地展开「图片 / 文件」，右侧发送键；
  已选附件在输入框上方显示缩略图与「名字 · 大小」，可一键移除。
- 空内容时发送键是灰的（不会误发空命令）；点回输入框自动收起附件面板。
- 会话详情与下发面板共用同一个组件 `ui/chat_composer.dart`，两处行为一致。

### 命令租约（P42 / P47，ADR-60）

- **命令不再永远停在「执行中」**：bridge 认领命令后每 30 秒续租，Hub 每 60 秒扫一次；
  执行侧失联（bridge 崩溃 / 断网 / 关机）超过约 2 分钟，命令自动收成
  `failed`（`cancelling` 收成 `cancelled`），`errorText` 写明「执行它的电脑没有心跳」。
- 新增 `POST /api/v1/commands/:id/heartbeat`（device）与 `commands.lease_expires_at`
  （migration 010）；`HUB_COMMAND_LEASE_SEC` / `HUB_COMMAND_LEASE_SWEEP_SEC` 可调。
- 终态命令不再接受 `running`：回收之后旧 bridge 醒来补报也不会把「失败」翻回「执行中」。
- `npm run reconcile` 保留为人工兜底（它看得到本机进程，仍是第一道）。

## 2026-11-04 · App 1.2.0+12 / Hub 0.1.0

### 更名

- **品牌定为 ClineHub（ADR-57 / ADR-58）**：App 标题 / 抽屉 / 引导页 / 设置页版本行 / 通知、
  落地页与全部文档里的项目名统一为 **ClineHub**（原展示名 `Cline Console`）。
- 随本次 `1.2.0+12` 发版生效：手机桌面图标名、通知标题、设置页版本行都显示 ClineHub；
  线上落地页的 title / 导航 / hero / footer 同步更新。
- 代码标识与部署契约一律不变（Flutter 包名 `cline_console`、Android `applicationId`、
  数据库 `cline_hub`、`HUB_*` 环境变量、服务器目录、仓库名、APK 文件名），
  老版本可以直接覆盖安装，token / 设置 / 历史数据都保留，Hub / bridge 不需要重新部署。

## 2026-11-03 · App 1.1.9+11 / Hub 0.1.0

### 新增

- **手机上实时看 DeepSeek 余额（P44，ADR-56）**：右侧菜单顶部新增「DeepSeek 余额」卡片
  （总额 / 充值 / 赠金 / 更新时间 + 可用标记，可手动刷新）。Hub 新增
  `GET /api/v1/deepseek/balance` 代查官方 `GET /user/balance`，API Key 只存在
  `server/.env` 的 `DEEPSEEK_API_KEY`，不会进 APK / 手机存储。
- 打开菜单、App 回前台、命令跑完都会自动刷新；Hub 侧 60 秒缓存，连点也不会打爆上游；
  查询失败时保留上一份数字并标注「上次的」。
- Hub 没配 Key 时不报错：卡片显示「Hub 未配置 DEEPSEEK_API_KEY」并给出配置提示。

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
- **设备列表 `GET /api/v1/devices`（ADR-47）**：只返回电脑端（bridge），带 `lastSeenAt` /
  会话数 / 待执行 / 执行中 / 最近会话时间；`device` token 只看自己，`app` / `admin` 看全部。
  App 用它渲染「已接入设备」卡片与带名字的设备 chip。
- **接入文档**：`docs/self-host.md`（从零自托管：服务器 → 电脑 → 手机闭环）、
  `docs/new-device.md`（第二台电脑）、`bridge/README.md`。
- **手工重发**：`cd bridge; npm run resend -- --missing-project`（或 `--session <id>` / `--recent <n>`），
  把会话快照 + 消息流重推一遍；服务端按 id upsert，不会产生重复气泡。支持 `--device` / `--token`
  以另一台设备的身份补历史，`--dry-run` 只列出要发什么。

### 修复

- 工作区页同一个项目显示成两组（`C:\...\cline-hub` 与 `C:/...\cline-hub`）：Hub 写入 / 读取
  统一路径写法，App 分组键按「分隔符无关」比较；`knownWorkspaces` 候选也去重（ADR-44）。
- 手机发 `act` 却按 `plan` 执行：bridge 用 `CLINE_GLOBAL_SETTINGS_PATH` 钉死模式。
- 反代缓冲导致 SSE 事件延迟：Caddy 加 `flush_interval -1`。
- 命令卡「执行中」：bridge 重启后的启动对账 + 每 60 秒 `reconcile()`。

## App 1.1.8 · 2026-11-03

- 优化：右侧划出菜单新增「浏览」区——「按工作区浏览」与「只看哪台电脑」都在这里，
  原来它们在会话页顶栏和设置页里，手机上要翻两处（ADR-54）。
- 优化：设置页删掉与抽屉重复的「已接入设备」卡片，默认设备改名「手填兜底」；
  设备在线状态、会话 / 待执行计数只在抽屉看一处，不会两边数字不一样。
- 优化：设备筛选生效时，三个列表顶部只留一条「只看 X · 看全部设备」提示条，
  不占常驻高度，也不会让人误以为数据丢了。
- 修复：卡片内开关点按时的 debug 断言（水波纹找不到 Material）。

## App 1.1.7 · 2026-11-03

- 新增：把手机上的文件 / 图片发给电脑。下发面板与会话底部输入框都能「发送文件 / 发送图片」
  （单份 ≤ 8 MB），输入框里的文字就是「要对它做什么」，也可以留空只让它读一遍（ADR-52 / 53）。
- 新增：命令详情显示附件名、大小、类型与**入库时间**；附件保留策略暂不做，先把时间记全。
- 新增：右侧划出菜单——电脑列表带在线状态与会话 / 待执行 / 执行中计数，点一台设为默认，
  另有「刷新数据 / 设置」入口。

## App 1.1.6 · 2026-11-03

- 新增：锁屏也提醒——命令运行期间挂一个 `dataSync` 前台服务（一条静音常驻通知），
  息屏后命令跑完也能立刻收到本地通知；可在设置 →「通知」→「锁屏也提醒」关掉（ADR-50）。
- 修复：同一个任务收到两条通知（「命令完成」+ 30 秒后「会话完成」）——按 `sessionId`
  归并，15 分钟内只提醒一次（ADR-48）。
- 优化：工作区按「设备 + 项目」分组，组头显示来自哪台电脑，组内卡片元信息也写设备名；
  两台机器的同名项目不再并成一组（ADR-49）。

## App 1.1.5 · 2026-11-02

- 新增：设置页「已接入设备」列表——每台电脑的在线状态、会话数、待执行 / 执行中命令，
  可直接设为默认设备（读 `GET /api/v1/devices`）。
- 新增：多设备筛选 chip 显示设备名（不再只有 id）；新接入、还没产生数据的电脑也会立刻出现。
- 修复：命令列表只显示设备名、看不到项目目录——卡片元信息改成「项目目录 · 设备 · 时间 · 耗时」，
  详情页同样带项目目录，完整路径仍在指令下面单独一行。
- 修复：执行中的命令「耗时」一直是同一个数字——现在每秒重算，命令结束自动停表。

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
