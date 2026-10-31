# server · Cline Hub

零框架 Node 服务（唯一依赖 `pg`）：REST + SSE + Postgres。
接口契约见 [`../docs/api.md`](../docs/api.md)，服务器准备见 [`../docs/server-prep.md`](../docs/server-prep.md)。

```
src/index.js        启动：连库 → 迁移 → 注册路由 → listen
src/env.js          .env 解析（不依赖 dotenv）
src/http.js         路由/auth 包装/JSON body/SSE
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

## 数据模型要点

- `clients`：`device`（Windows bridge）/ `app`（手机）。token 只存 `sha256`，`last_seen_at` 每分钟最多写一次。
- `sessions`：主键 `(device_id, session_id)`，重复上报走 upsert；`result_text` 存全文，列表查询只取前 400 字。
- `hooks`：`payload` 原样 `jsonb`，另抽 `title`/`body` 便于列表展示。
- `commands`：`pending → delivered → running → done/failed/cancelled`；
  领取用 `for update skip locked`，多实例也不会重复取。

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
