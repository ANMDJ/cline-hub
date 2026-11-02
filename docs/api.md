# Hub API 约定（v1）

Base URL：本机 `http://127.0.0.1:3100`，线上 `https://hub.littlewish.top:8443`。

## 鉴权

所有接口（除 `/health`）都要带 token：

```
Authorization: Bearer <token>
```

SSE 例外：`GET /api/v1/events?token=<token>`（EventSource 不能设置请求头）。

| 角色 | 来源 | 能做什么 |
|---|---|---|
| `device` | `create-device --id <id>` | 上报 session/hook、拉取并回报远程命令 |
| `app` | `create-device --role app` | 读会话、下发命令 |
| `admin` | `HUB_ADMIN_TOKEN` 环境变量 | 管理 clients、调试时跨设备读写 |

- token 只在创建时明文返回一次，库里存 `sha256`。
- 同一个 token 只能写自己 `deviceId` 的数据，手填别人的 `deviceId` 返回 `403 device_mismatch`。
- **读接口按设备隔离**（ADR-43）：`device` token 只能读自己的行，传别人的 `deviceId` 直接
  `403 device_mismatch`；`app` / `admin` 不传 = 全部设备，传了 = 只看那一台。SSE 同理。

## 错误格式

```json
{ "ok": false, "code": "invalid_field", "message": "prompt is required" }
```

| 状态码 | 含义 |
|---|---|
| 400 | 参数不合法（`invalid_field` / `invalid_json` / `unknown_device`） |
| 401 | 没带 token / token 无效 |
| 403 | 角色不够，或跨设备写入 |
| 404 | 资源不存在 |
| 409 | client id 已存在 |
| 413 | body 超过 `HUB_MAX_BODY_BYTES`（默认 4 MB） |
| 500 / 503 | 服务端异常 / 数据库不可用 |

## 接口一览

| 方法 | 路径 | 角色 | 说明 |
|---|---|---|---|
| GET | `/api/v1/health` | 匿名 | 存活 + DB 延迟 |
| GET | `/api/v1/devices` | any | 电脑端（bridge）列表：在线时间 / 会话数 / 命令计数 |
| GET | `/api/v1/clients` | admin | 设备列表（含会话数、待执行命令数） |
| POST | `/api/v1/clients` | admin | 创建设备，返回一次性 token |
| DELETE | `/api/v1/clients/:id?confirm=1` | admin | 删除设备（级联删数据） |
| POST | `/api/v1/sessions` | device | 上报/更新一条会话（幂等 upsert） |
| POST | `/api/v1/sessions/:sessionId/messages` | device | 增量上报会话消息（按 message_id 幂等 upsert） |
| GET | `/api/v1/sessions/:sessionId/messages` | any | 会话消息流（seq 升序，`after` 做增量续拉） |
| GET | `/api/v1/sessions` | any | 会话列表（游标分页 + 过滤 + 搜索） |
| GET | `/api/v1/sessions/:sessionId` | any | 会话详情（含结果全文与命令列表） |
| POST | `/api/v1/hooks` | device | 上报 hook 事件 |
| GET | `/api/v1/hooks` | any | 事件流（按 id 倒序） |
| POST | `/api/v1/commands` | app | 下发远程命令 |
| GET | `/api/v1/commands` | any | 命令列表 |
| GET | `/api/v1/commands/pending` | device | 领取待执行命令（自动置为 `delivered`） |
| GET | `/api/v1/commands/:id` | any | 命令详情 |
| POST | `/api/v1/commands/:id/cancel` | app | 取消命令（排队中直接 `cancelled`，执行中先 `cancelling`） |
| PATCH | `/api/v1/commands/:id` | device | 回报 `running` / `done` / `failed` / `cancelled` |
| GET | `/api/v1/events` | any | SSE 实时事件 |

`GET /api/v1/sessions` 的过滤参数：`limit`、`cursor`、`status`、`workspace`、`project`、
`deviceId`、`q`。
`project` 精确匹配 bridge 上报的项目名；散会话（`projectKind=loose`）的 `project` 是 `null`，
按 `project` 过滤取不到它们。
`cursor` 取上一页响应里的 `nextCursor`（格式 `<sortAt ISO>|<sessionId>`）。

### 读接口的设备范围（ADR-43）

| 调用方 | 不传 `deviceId` | 传 `deviceId` |
|---|---|---|
| `device` | 只看自己 | 必须是自己，否则 `403 device_mismatch` |
| `app` / `admin` | 全部设备 | 只看指定设备 |

适用于 `GET /sessions`、`GET /sessions/:sessionId`、`GET /sessions/:sessionId/messages`、
`GET /commands`、`GET /commands/:id`、`GET /hooks`、`GET /events`（SSE）、`GET /devices`。
`device` token 读别人的命令详情返回 `403 forbidden`；命令**领取**（`/commands/pending`）
一直是「只领自己的」，不受影响。

## 设备列表（`GET /api/v1/devices`，ADR-47）

给 App 渲染「已接入设备」和多设备筛选 chip。只返回 `role='device'` 的 client（手机自己的
`app` client 不算设备）。

```json
{
  "ok": true,
  "items": [
    {
      "id": "localone",
      "name": "LocalOne-Windows",
      "createdAt": "2026-11-01T00:00:00.000Z",
      "lastSeenAt": "2026-11-02T05:00:00.000Z",
      "sessionCount": 12,
      "commandCount": 4,
      "pendingCommands": 1,
      "runningCommands": 2,
      "lastSessionAt": "2026-11-02T04:59:00.000Z",
      "lastCommandAt": "2026-11-02T04:58:00.000Z"
    }
  ]
}
```

| 字段 | 含义 |
|---|---|
| `lastSeenAt` | bridge 最近一次请求 Hub 的时间（服务端 60 秒节流写入）；App 用「2 分钟内」粗略判在线 |
| `sessionCount` / `commandCount` | 该设备的历史总数 |
| `pendingCommands` | `pending` + `delivered`（还没开始跑） |
| `runningCommands` | `running` + `cancelling` |
| `lastSessionAt` | 最近一条会话的有效时间（`ended_at → started_at → updated_at → collected_at` 依次兜底） |
| `lastCommandAt` | 最近一条命令的创建时间 |

- `app` / `admin`：返回全部电脑端；`device` token：只返回自己（与 ADR-43 一致）。
- 没有这个接口时 App 会退回「从已加载数据里猜设备」；升级 Hub 后设备列表更完整
  （新接入、还没产生数据的电脑也会出现）。

## 会话上报（bridge 用）

`POST /api/v1/sessions`

```json
{
  "deviceId": "localone",
  "session": {
    "sessionId": "1793406873889_kz6g7",
    "source": "vscode",
    "status": "completed",
    "exitCode": 0,
    "provider": "cline",
    "model": "cline-free/deepseek-v4.1-flash",
    "cwd": "C:\\Users\\alice\\.cline\\data\\workspaces\\chat",
    "workspaceRoot": "C:\\Users\\alice\\.cline\\data\\workspaces\\chat",
    "workspace": "chat",
    "project": "cline-hub",
    "projectRoot": "C:\\Users\\alice\\.cline\\data\\workspaces\\chat\\cline-hub",
    "projectKind": "project",
    "prompt": "开发这个app",
    "startedAt": "2026-09-20T02:47:19.711Z",
    "endedAt": "2026-09-20T07:43:15.138Z",
    "updatedAt": "2026-09-20T07:43:15.139Z",
    "resultOk": true,
    "resultError": "",
    "resultText": "构建完成。……",
    "resultTruncated": false,
    "userPrompt": "开发这个app",
    "commands": [{ "id": "toolu_1", "tool": "run_commands", "command": "npm test" }],
    "metrics": { "messages": 120, "thinkingChars": 8000, "commandCount": 1 },
    "collectedAt": "2026-10-31T09:11:34.300Z"
  }
}
```

响应：`{ "ok": true, "sessionId": "...", "inserted": true }`

`workspaceRoot` / `projectRoot` 入库前会过 `normalizeFsPath()`（`C:/a/b` → `C:\a\b`，
去重复 / 尾部斜杠；大小写与 POSIX 路径不动），读取时再归一化一次，历史行也能按目录合并。
会话里的 `workspace` 只是展示用的目录名，不做归一化；命令 / hook 里的 `workspace` 可能是绝对路径，
会一起归一化。

- 幂等：`(device_id, session_id)` 唯一，重复上报走 `update`，`inserted` 反映是否新建。
- 时间接受 ISO8601 或 epoch 毫秒；无法解析时为 `null`。
- `commands` 全量覆盖（bridge 每次上报的都是该会话最新抽取结果）。

## 会话消息（bridge 增量上报）

`POST /api/v1/sessions/:sessionId/messages`（device）

```json
{
  "deviceId": "localone",
  "messages": [
    { "id": "d7287361-...:0", "role": "user", "kind": "text", "text": "如何启动 bridge", "seq": 0, "ts": "2026-11-01T03:53:40.411Z" },
    { "id": "msg_uEIvbzwi:1", "role": "assistant", "kind": "command", "text": "ls -la", "tool": "run_commands", "seq": 2, "ts": "2026-11-01T03:53:45.570Z" }
  ]
}
```

- 主键 `(device_id, session_id, message_id)`：流式回复的同一条消息会被重发覆盖，
  详情页不会出现重复气泡。
- `kind`：`text` = 正文，`command` = 白名单工具的调用（命令过程），
  `question` = Cline 的 `ask_question`（带 `options`，手机端要渲染成按钮）。
- 一次最多 200 条；bridge 按「40 条 **或** 64KB 先到者」切批（单条可到 20000 字）。
- `text` 超过 40000 字会被服务端截断（bridge 侧 `maxTextChars` 默认 20000）。
- `truncated: true` 表示 bridge 侧已截断，手机上的文本不是全文。
- `options`：`kind=question` 的可选项数组，最多 8 条；其他 kind 为空数组。

`GET /api/v1/sessions/:sessionId/messages?limit=800&after=<seq>`（any）

```json
{ "ok": true, "items": [ { "messageId": "...", "seq": 0, "role": "user", "kind": "text", "text": "...", "truncated": false, "options": [], "tool": null, "ts": "..." } ], "hasMore": false }
```

- 按 `seq asc` 返回；`after` 只返回 `seq > after` 的部分，用于会话还在跑时续拉。
- 注意实现细节：**不传 `after` 时不能当成 0**，否则 `seq=0` 的第一条（用户原话）会被永久过滤掉。
- 「取会话开头」= `after=-1&limit=12`：只要有 `after` 就按升序取，`seq > -1` 即从第 0 条开始。
  不要写 `after=0`（会漏掉 `seq=0`）；即使以后语义改成 `>=`，`-1` 依然成立。
- 不传 `after` 时取的是**最近** `limit` 条（内部 desc 再反转），翻更早用 `before=<最小 seq>`。

## App 发布信息（客户端自更新）

`GET /api/v1/app/latest`（any）→ 服务器上 `releases/latest.json` 的内容：

```json
{
  "ok": true,
  "version": "1.1.0",
  "build": 2,
  "notes": ["修复 ACT 模式", "长文本折叠"],
  "apkUrl": "https://hub.littlewish.top:8443/app/cline-console-1.1.0.apk",
  "sha256": "…",
  "publishedAt": "2026-11-02T02:40:00.000Z"
}
```

- 清单由 `app/scripts/release-apk.mjs` 生成，默认放 `<server>/releases/latest.json`，
  可用 `HUB_APP_RELEASE_FILE` 覆盖。
- 没发布过时返回 `404 not_found`，客户端据此显示「服务器还没有发布过 APK」。
- APK 本身由 Caddy 的 `file_server` 从 `/var/www/cline-hub/app/` 直出，不经过 Hub 进程。

## 会话列表

```
GET /api/v1/sessions?limit=30&workspace=chat&status=completed&q=Flutter&cursor=<nextCursor>
```

- `limit`：1–200，默认 50。
- 排序：`coalesce(ended_at, updated_at, started_at) desc nulls last`。
  进行中的会话 `ended_at` 为空，用 `updated_at` 排序才会跟着最新一条消息走；
  游标与 `ORDER BY` 必须用同一个表达式，否则翻页会漏行。
- 过滤：`workspace` / `status` / `deviceId` 精确匹配；`q` 对 `result_text`、`prompt`、`user_prompt` 做 `ilike` 模糊匹配。
- 分页：把响应里的 `nextCursor` 原样回传；`nextCursor` 为 `null` 表示到底。

```json
{
  "ok": true,
  "items": [
    {
      "deviceId": "localone",
      "sessionId": "1793406873889_kz6g7",
      "workspace": "kids_points_app",
      "status": "completed",
      "exitCode": 0,
      "provider": "cline",
      "model": "cline-free/deepseek-v4.1-flash",
      "startedAt": "2026-10-30T23:14:33.889Z",
      "endedAt": "2026-10-31T01:02:11.000Z",
      "prompt": "结论先说：……",
      "userPrompt": "这个阶段要不要上 Docker",
      "resultOk": true,
      "resultPreview": "结论先说：你现在这个阶段……",
      "commandCount": 26,
      "metrics": { "messages": 240, "thinkingChars": 0, "commandCount": 26 },
      "sortAt": "2026-10-31T01:02:11.000Z"
    }
  ],
  "nextCursor": "2026-10-31T01:02:11.000Z|1793406873889_kz6g7"
}
```

列表**不返回** `resultText` 全文，只有 `resultPreview` + `commandCount`，避免手机上拉几十 MB。

`resultPreview` 是**服务端洗过的纯文本**（`server/src/text.js`）：先剥 ANSI 控制序列，
再剥 Markdown 记号（标题 / 代码围栏 / 粗体 / 链接 / 表格竖线），多行折成一行，
最后按**码点**截到 400 字（截断时以 `…` 结尾，不会劈开 emoji）。
清洗取的是原始 `result_text` 的前 2000 字——只看前 400 字的话，客户端拿到的可能全是代码围栏和标题记号。

SSE 的 `session` 事件里也带 `resultPreview`，同一套清洗，上限 200 字。
命令输出（`commands.resultText`）不做服务端清洗：那是终端回放，App 只在展示/复制时去 ANSI。

## 会话详情

`GET /api/v1/sessions/:sessionId` → `{ ok, session }`，`session` 比列表项多两个字段：

- `resultText`：结果全文（bridge 侧已按 `maxResultChars` 截断，默认 4000 字）。
- `commands`：`[{ id, tool, command }]`，每个命令已按 `maxCommandChars`（2000）截断。

## Hook 上报

`POST /api/v1/hooks`

```json
{ "deviceId": "localone", "event": "agent_end", "payload": { "...": "hook 原始 JSON" }, "receivedAt": "2026-10-31T09:11:35.000Z" }
```

- `payload` 原样存进 `jsonb`；`title` / `message` 会额外抽出来做列表展示。
- `sessionId` 可选：bridge 的兜底通知会带上它，App 的动态卡片靠它跳进会话详情。
- `GET /api/v1/hooks?limit=50&beforeId=123`：倒序分页。

### 完成通知从哪来

Cline 4.1.26 起把全局 hooks 目录改为工作区级 `.clinerules/hooks`，机器上原有外挂 hook
不再触发。所以 bridge 自己在 `sessions.db` 里盯状态跃迁（`running` →
`completed` / `failed` / `cancelled`），发现就补一条 `session_done` /
`session_failed` / `session_cancelled` 事件，不依赖 Cline 侧的任何配置。

## 远程命令

### 下发（App）

```json
POST /api/v1/commands
{ "deviceId": "localone", "prompt": "把 kids_points_app 的测试跑一遍", "mode": "plan", "workspace": "C:\\Users\\alice\\projects\\kids_points_app" }
```

- `mode`：`plan`（默认，只出方案）/ `act` / `yolo`。
- `sessionId` 可选：记录「这条指令来自哪个会话」。注意 cline CLI 4.x 的 `--id` 续会话要求 TTY，
  bridge 是无头进程，所以**实际执行一律 `cline -c <workspace>` 新开会话**（2026-11-01 实测）。
  该字段目前只用于溯源，客户端不要指望消息出现在原会话里；新会话会由 bridge 下一轮扫描自动上报。
- 返回 `{ ok, command: { id, status: "pending", sessionId, ... } }`。

### 领取（bridge）

`GET /api/v1/commands/pending?limit=10` → `{ ok, deviceId, items: [...] }`

- 事务内 `for update skip locked` 取 `pending`，立即置 `delivered`，保证多进程不重复领取。
- 空列表就是 `items: []`（正常情况，不要当错误）。

### 取消（App）

`POST /api/v1/commands/:id/cancel`（app）→ `{ ok, command }`

- 状态机分两种，客户端只看返回的 `status`：
  - `pending` / `delivered` → 直接 `cancelled`（bridge 还没 spawn，不用杀进程）；
  - `running` → `cancelling`，bridge 下一轮轮询（约 5 秒）按 commandId 精确杀进程树，
    再回写 `cancelled`，`errorText` 说明原因。
- 已经结束（`done` / `failed` / `cancelled`）返回 **409 `already_finished`**：取消不覆盖历史结果。
- 取消时间写进 `cancel_requested_at`，命令对象的 `cancelRequestedAt` 会返回。
- bridge 侧的防回翻规则：命令已是 `cancelled` 时，后续 `running` / `done` 回报一律忽略；
  `cancelling` 期间迟到的 `running`（补 pid / sessionId）不会把状态翻回 `running`。
- bridge 重启时还停在 `cancelling` 的命令由启动对账收尾：进程没了就回写 `cancelled`；
  进程还在（且 pid + 启动时间双校验通过）就精确杀掉再回写。

### 回报（bridge）

```json
PATCH /api/v1/commands/cmd_9f2c1a4b3d5e
{
  "status": "running",
  "pid": 23724,
  "pidStartedAt": "2026-11-02T03:44:27.827Z",
  "runner": "cline",
  "resultText": null,
  "errorText": null,
  "sessionId": "1793548380890_qij68"
}
```

- 允许的状态：`running` / `done` / `failed` / `cancelled`。
- `cancelled` 只由 bridge 在「手机端取消后杀掉进程」这条路径回写；如果命令在开始前
  就被取消（HTTP 已是 `cancelled`），这次 PATCH 会被服务端原样忽略，不会翻回成功。
- `running` 首次会写 `started_at`；终态写 `finished_at`。
- `sessionId`：bridge 新开 cline 会话后回写（`coalesce` 只写一次，不会被后续上报清空），
  App 的命令详情据此直接跳进那条会话。
- `pid` / `pidStartedAt` / `runner`：bridge spawn 成功立刻上报，同样 `coalesce` 只写一次。
  `pid` 必须是正整数（非法值 400），`pidStartedAt` 接受 ISO 字符串或 epoch 毫秒。
  三者会原样出现在命令对象里（`pid` / `pidStartedAt` / `runner`），供 App 展示与排障。
- **不要只凭 `pid` 杀进程**：Windows 会复用 PID。本机用 `cd bridge; npm run ps` 双校验
  （pid + 启动时间），要停就 `npm run ps -- --kill <commandId>`（ADR-33）。

## SSE 事件

`GET /api/v1/events?token=<token>`，`content-type: text/event-stream`，25 秒一次 `: ping` 心跳。

| event | 触发时机 | data 关键字段 |
|---|---|---|
| `session` | bridge 上报会话后 | `sessionId` / `status` / `workspace` / `endedAt` / `resultPreview` |
| `hook` | 收到 hook | `id` / `event` / `title` / `body` |
| `command` | App 新建命令 | 完整命令对象 |
| `command.update` | 命令状态变化（被领取 / 执行完） | 完整命令对象 |

手机端建议：前台用 SSE，退到后台就断开、回到前台先 `GET /api/v1/sessions?limit=30` 再重连。
