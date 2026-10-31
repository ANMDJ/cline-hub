# 关键技术决策（ADR 摘要）

记录「为什么这么做」，避免以后重写时踩同一个坑。

## 1. Hub 用 `node:http` 裸写，不引 NestJS/Prisma

- 只有 15 条路由、一个 Postgres 连接池，框架带来的抽象成本远大于收益；唯一依赖是 `pg`。
- 好处：镜像 200MB 出头、冷启动 <1s、没有 ORM 迁移黑盒（迁移脚本就是按文件顺序执行的 SQL）。
- 代价：参数校验、路由匹配要自己写（`src/http.js` + `src/util.js`，约 200 行，够用）。

## 2. 会话列表不返回全文

`GET /sessions` 每条只给 `resultPreview`（400 字符）+ `commandCount`；`resultText` 与 `commands`
只在 `GET /sessions/:id` 返回。理由：一条会话的结果文本可达数万字符，59 条列表就是几 MB，
手机流量和渲染都扛不住。

## 3. Token 只存哈希，比较用 `timingSafeEqual`

库里存 `sha256(token)`，明文只在 `create-device` 打印那一次。角色三分：`admin` / `device` / `app`；
跨设备写操作一律 403 `device_mismatch`。

## 4. 命令走轮询，不走 WebSocket

bridge 要「零依赖、断了也能自愈」，WebSocket 得引库还要处理重连；轮询 + 服务端
`FOR UPDATE SKIP LOCKED` 认领已经是**至少一次投递**的语义，够用且天然防重。
手机端的实时性由 SSE 单独解决（见 5）。

## 5. SSE 必须有 `flush_interval -1`

Caddy 默认会缓冲响应，导致 `GET /api/v1/events` 的事件攒着不发。Caddyfile 里对
`/api/v1/events*` 单独 `reverse_proxy ... { flush_interval -1 }`，并回 `x-accel-buffering: no`，
25s 一个心跳防中间层掐连接。

## 6. 远程命令的执行方式是可配置模板，不硬编码 `cline`

本机没有 `cline` CLI（只有 VS Code 扩展），把执行器写成 `template` + `shell`：

```json
{ "enabled": true, "template": "{prompt}", "shell": "powershell", "allowModes": ["plan", "act"] }
```

- 默认 `{prompt}` 当脚本跑 → 今天就能用（实测 6s 闭环）。
- 装了 Cline CLI 后改成 `cline --yolo "{prompt}"`，代码不用动。
- 脚本先落成临时文件再执行，绕开 Windows 引号/换行转义地狱；超时用 `taskkill /t /f` 杀整棵树。
- 安全默认：`enabled=false`、`yolo` 不在 `allowModes` 里，被拒命令直接 `failed` 并写明原因。

## 7. 部署环境的三条硬约束（2026-10-31 实测）

| 约束 | 表现 | 对策 |
|---|---|---|
| 国内机连不上 Docker Hub | `dial tcp ...registry-1.docker.io:443 i/o timeout` | `/etc/docker/daemon.json` 加 `mirror.ccs.tencentyun.com` |
| `postgres:18` 改了数据目录 | 挂 `/var/lib/postgresql/data` → 容器无限重启 | 卷挂 `/var/lib/postgresql`（`PGDATA=/var/lib/postgresql/18/docker`） |
| caddy.service 有 `ProtectSystem=full` | 写 `/var/log/caddy/*` → `permission denied`，reload 失败 | 日志写 `/var/lib/caddy/hub.log` |

## 8. Windows 端后台启动不能用 bash 的 `nohup ... &`

在 Git Bash 里 `nohup node ... &` 会让 Cline 的终端 shell 一起被杀掉。统一用：

```powershell
Start-Process -WindowStyle Hidden node -ArgumentList 'src/index.js' -WorkingDirectory <bridge 目录>
```

开机自启：`schtasks /create /sc onlogon` 需要**管理员**权限（普通权限报 `ERROR: Access is denied.`），
所以改用启动文件夹的 `ClineBridge.vbs`（见 `deploy/windows/ClineBridge.vbs`，`WScript.Shell.Run(..., 0, False)`
无窗口启动）。两种方式二选一即可，别同时开（会抢 3210 端口）。

## 9. 仓库里不出现任何真实口令

`bridge/config.json`、`bridge/state.json`、`server/.env`、`.secrets/`、`*.pem` 全部 gitignore；
token 落盘只在本机 `.secrets/*.token.txt`，用时由脚本读取，不写进日志和文档。

## 10. 仓库根目录 = `~/.cline/data/workspaces/chat/cline-hub`

与 kids 项目（`kids_points_app`）同级，方便同一 Cline 会话里跨项目引用。

迁移时的两个 Windows 细节（2026-10-31 实际踩到）：

- 整个目录 `mv` 会被拒（`Permission denied` / `You do not have sufficient access rights`），
  因为目录里还开着 .git 与 node 句柄 —— 先 `taskkill` 掉 bridge，再**逐个子项** `mv`；
  `.git` 若被拆成两半，用 `cp -a <src>/.git/. <dst>/.git/` 补齐后 `git fsck` 校验。
- 迁移后必须同步的绝对路径：`README.md`、`deploy/README.md`、`docs/bridge-notes.md`、
  `deploy/windows/ClineBridge.vbs` 以及启动文件夹里那份 VBS。
  `bridge/config.json` 不含绝对路径（`dataDir` 默认 `~/.cline/data`，`state.json`/`outbox.json` 在 `bridgeRoot`），
  所以会话水位线和 outbox 跟着仓库走，不会重复上报。

