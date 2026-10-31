# Hub API 约定（v1）

Base URL：本机 `http://127.0.0.1:3100`，线上 `https://hub.littlewish.top`。

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
| GET | `/api/v1/clients` | admin | 设备列表（含会话数、待执行命令数） |
| POST | `/api/v1/clients` | admin | 创建设备，返回一次性 token |
| DELETE | `/api/v1/clients/:id?confirm=1` | admin | 删除设备（级联删数据） |
| POST | `/api/v1/sessions` | device | 上报/更新一条会话（幂等 upsert） |
| GET | `/api/v1/sessions` | any | 会话列表（游标分页 + 过滤 + 搜索） |
| GET | `/api/v1/sessions/:sessionId` | any | 会话详情（含结果全文与命令列表） |
| POST | `/api/v1/hooks` | device | 上报 hook 事件 |
| GET | `/api/v1/hooks` | any | 事件流（按 id 倒序） |
| POST | `/api/v1/commands` | app | 下发远程命令 |
| GET | `/api/v1/commands` | any | 命令列表 |
| GET | `/api/v1/commands/pending` | device | 领取待执行命令（自动置为 `delivered`） |
| GET | `/api/v1/commands/:id` | any | 命令详情 |
| PATCH | `/api/v1/commands/:id` | device | 回报 `running` / `done` / `failed` / `cancelled` |
| GET | `/api/v1/events` | any | SSE 实时事件 |

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

- 幂等：`(device_id, session_id)` 唯一，重复上报走 `update`，`inserted` 反映是否新建。
- 时间接受 ISO8601 或 epoch 毫秒；无法解析时为 `null`。
- `commands` 全量覆盖（bridge 每次上报的都是该会话最新抽取结果）。

## 会话列表

```
GET /api/v1/sessions?limit=30&workspace=chat&status=completed&q=Flutter&cursor=<nextCursor>
```

- `limit`：1–200，默认 50。
- 排序：`coalesce(ended_at, started_at, updated_at) desc`。
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
      "resultPreview": "结论先说：**你现在这个阶段……",
      "commandCount": 26,
      "metrics": { "messages": 240, "thinkingChars": 0, "commandCount": 26 },
      "sortAt": "2026-10-31T01:02:11.000Z"
    }
  ],
  "nextCursor": "2026-10-31T01:02:11.000Z|1793406873889_kz6g7"
}
```

列表**不返回** `resultText` 全文，只有 `resultPreview`（前 400 字）+ `commandCount`，避免手机上拉几十 MB。

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
- `GET /api/v1/hooks?limit=50&beforeId=123`：倒序分页。

## 远程命令

### 下发（App）

```json
POST /api/v1/commands
{ "deviceId": "localone", "prompt": "把 kids_points_app 的测试跑一遍", "mode": "plan", "workspace": "C:\\Users\\alice\\projects\\kids_points_app" }
```

- `mode`：`plan`（默认，只出方案）/ `act` / `yolo`。
- 返回 `{ ok, command: { id, status: "pending", ... } }`。

### 领取（bridge）

`GET /api/v1/commands/pending?limit=10` → `{ ok, deviceId, items: [...] }`

- 事务内 `for update skip locked` 取 `pending`，立即置 `delivered`，保证多进程不重复领取。
- 空列表就是 `items: []`（正常情况，不要当错误）。

### 回报（bridge）

```json
PATCH /api/v1/commands/cmd_9f2c1a4b3d5e
{ "status": "done", "resultText": "全部 42 个测试通过", "errorText": null }
```

- 允许的状态：`running` / `done` / `failed` / `cancelled`。
- `running` 首次会写 `started_at`；终态写 `finished_at`。

## SSE 事件

`GET /api/v1/events?token=<token>`，`content-type: text/event-stream`，25 秒一次 `: ping` 心跳。

| event | 触发时机 | data 关键字段 |
|---|---|---|
| `session` | bridge 上报会话后 | `sessionId` / `status` / `workspace` / `endedAt` / `resultPreview` |
| `hook` | 收到 hook | `id` / `event` / `title` / `body` |
| `command` | App 新建命令 | 完整命令对象 |
| `command.update` | 命令状态变化（被领取 / 执行完） | 完整命令对象 |

手机端建议：前台用 SSE，退到后台就断开、回到前台先 `GET /api/v1/sessions?limit=30` 再重连。
