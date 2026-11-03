# server · ClineHub

零框架 Node 服务（唯一依赖 `pg`）：REST + SSE + Postgres。
接口契约见 [`../docs/api.md`](../docs/api.md)，服务器准备见 [`../docs/server-prep.md`](../docs/server-prep.md)。

```
src/index.js        启动：连库 → 迁移 → 注册路由 → listen
src/env.js          .env 解析（不依赖 dotenv）
src/http.js         路由/auth 包装/JSON body/SSE
src/net.js          真实 IP 解析 / CIDR 白名单 / 令牌桶限流
src/text.js         列表预览纯文本化（剥 ANSI / Markdown、折叠空白、按码点截断）
src/routes/*.js     clients / sessions / hooks / commands
migrations/*.sql    幂等建表，按文件名顺序只执行一次
scripts/create-device.mjs  建设备并打印一次性 token
```

## 本机

```powershell
copy .env.example .env
npm install
npm run migrate
npm run create-device -- --id localone --name "LocalOne-Windows"
Start-Process -WindowStyle Hidden node -ArgumentList 'src/index.js' -WorkingDirectory $PWD
curl http://127.0.0.1:3100/api/v1/health
```

> 不要用 Git Bash 的 `nohup node src/index.js &`：它会把 Cline 的终端 shell 一起带走，
> 后续命令全部报 “shell process has exited”。用 PowerShell 的 `Start-Process` 或 `npm start` 另开窗口。

## 环境变量

| 变量 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `HUB_DATABASE_URL` | ✅ | — | `postgresql://user:pass@host:5432/cline_hub` |
| `HUB_ADMIN_TOKEN` | 建 client 时必填 | — | 管理令牌，≥16 字符，建议 48 位随机 |
| `HUB_HOST` / `HUB_PORT` | | `127.0.0.1` / `3100` | 生产保持 loopback，由 Caddy 反代 |
| `HUB_AUTO_MIGRATE` | | `1` | 生产设 `0`，改 `npm run migrate` 显式执行 |
| `HUB_LOG_LEVEL` | | `info` | `debug` 会打印 SSE 连接细节 |
| `HUB_LOG_FILE` | | 空（仅 stdout） | 写文件同时保留控制台输出 |
| `HUB_CORS_ORIGIN` | | `*` | Flutter Web 调试时可收紧 |
| `HUB_MAX_BODY_BYTES` | | 4 MB | 单条会话含 300 条命令也远小于此值 |
| `HUB_RATE_LIMIT_PER_SEC` | | `5` | 每 IP 令牌桶恢复速率（请求/秒） |
| `HUB_RATE_LIMIT_BURST` | | `120` | 每 IP 瞬时突发上限，超过返回 `429` + `retry-after` |
| `HUB_ALLOW_IPS` | | 空 | 逗号分隔的 IP / CIDR 白名单；空 = 不限 IP，本机回环永远放行 |
| `HUB_COMMAND_LEASE_SEC` | | `120` | 命令租约秒数：bridge 认领后必须在这个时间内续租（P42），过期自动收成 `failed: orphaned` |
| `HUB_COMMAND_LEASE_SWEEP_SEC` | | `60` | 过期租约扫描间隔（秒）；bridge 硬崩后最迟约 3 分钟自动收尾 |
| `DEEPSEEK_API_KEY` | | 空 | App「DeepSeek 余额」卡片用。Key 只在 Hub 上，留空时接口返回 `configured:false` |
| `DEEPSEEK_BASE_URL` | | `https://api.deepseek.com` | 上游地址（一般不用改） |
| `DEEPSEEK_BALANCE_TTL_SEC` | | `60` | 余额短缓存秒数：窗口内重复请求不重复打上游 |
| `DEEPSEEK_TIMEOUT_MS` | | `8000` | 上游超时；超时返回 `504 deepseek_timeout` |

## 数据模型要点

- `clients`：`device`（Windows bridge）/ `app`（手机）。token 只存 `sha256`，`last_seen_at` 每分钟最多写一次。
- `sessions`：主键 `(device_id, session_id)`，重复上报走 upsert；`result_text` 存全文，列表查询取前 2000 字原文、由 `src/text.js` 洗成 400 字纯文本预览。
- `hooks`：`payload` 原样 `jsonb`，另抽 `title`/`body` 便于列表展示。
- `commands`：`pending → delivered → running → done/failed/cancelled`，
  手机端取消执行中的命令会先进入 `cancelling`（bridge 停完进程再回写 `cancelled`）；
  领取用 `for update skip locked`，多实例也不会重复取。
- 路径列（`sessions.workspace_root` / `project_root`、`commands.workspace`、`hooks.workspace`）
  写入前过 `normalizeFsPath()`：`C:/a/b` 与 `C:\a\b` 存成同一串；读取时再归一化一次，
  历史行不用回填也能按目录合并（ADR-44）。只动 Windows 风格的路径，POSIX 路径原样保留。

## 设备列表

`GET /api/v1/devices`（`auth: any`）给 App 用：只返回 `role='device'`，`device` token 只看自己，
`app` / `admin` 看全部。字段与口径见 [`../docs/api.md`](../docs/api.md)「设备列表」。
`GET /api/v1/clients` 仍是 admin 专属（含 `app` client 与创建 / 删除）。

## DeepSeek 余额（P44）

`GET /api/v1/deepseek/balance`（`auth: app`）由 Hub 代查 DeepSeek 的 `GET /user/balance`：
Key 从 `DEEPSEEK_API_KEY` 读，**不下发给 App**，日志里也不打印。

- 进程内缓存 `DEEPSEEK_BALANCE_TTL_SEC`（默认 60 秒）；`?refresh=1` 强制绕过。
- 上游 401/403 **不能透传**（App 会误判成自己的 Hub token 失效），统一转
  `502 deepseek_auth_failed`。
- 刷新失败但手里有旧数据时返回旧数据 + `stale: true`，卡片只多一行说明。
- 没配 Key 时返回 200 + `configured:false` + `hint`：卡片显示「去服务器配置」而不是报错。

配置：`server/.env` 加 `DEEPSEEK_API_KEY=sk-...` 后重启容器（`docker compose up -d hub`）。
字段与错误码见 [`../docs/api.md`](../docs/api.md)。

## 读接口的设备范围

`src/util.js` 的 `readDeviceScope()` 统一处理：`device` token 只能读自己的行（`deviceId`
不匹配直接 `403 device_mismatch`），`app` / `admin` 不传即全部、传了即筛选。

`src/http.js` 的 `sseMayReceive()` 用同一规则过滤广播：`device` 连接只收 `deviceId`
与之一致的事件，负载里没有 `deviceId` 的事件不发（宁可少推，也不串设备）。ADR-43。

## Docker

```bash
cp .env.example .env      # 填库地址和管理令牌
docker compose build
docker compose run --rm hub node src/migrate.js
docker compose up -d
docker compose logs -f hub
```

`network_mode: host` 让容器直接占用 `127.0.0.1:3100`，Caddy 反代 `hub.littlewish.top`：

```
hub.littlewish.top {
    reverse_proxy 127.0.0.1:3100
}
```

SSE 需要关掉反代缓冲——上面的 `reverse_proxy` 默认就不缓冲，配合响应头
`x-accel-buffering: no` 已处理。
