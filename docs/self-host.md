# 从零自托管：手机 + 一台或多台电脑的完整闭环

> **这份文档写给第一次拿到仓库的人**：从一台空服务器开始，到「手机上看到电脑的 Cline 会话、
> 并能从手机下发命令回电脑执行」全部跑通。每一步都给了验收命令，卡住时按最后一节排障。
>
> 只想给现有 Hub 加一台电脑？看 [`new-device.md`](new-device.md)，不用重读这篇。

## 0. 先看懂四件东西

```
┌────────────┐   HTTPS/JSON + SSE   ┌──────────────┐
│ 手机 App   │ ───────────────────► │     Hub      │
│ (Flutter)  │ ◄─────────────────── │ Node + PG    │
└────────────┘                      └──────┬───────┘
       ▲                                   │ 轮询命令 / 上报会话
       │ 通知（可选 ntfy）                   │
       │                            ┌──────▼───────┐
       └────────────────────────────│  bridge      │ 每台 Windows 一个
                                    │ (Node 常驻)  │
                                    └──────┬───────┘
                                           │ 读 sessions.db / messages.json
                                    ┌──────▼───────┐
                                    │ Cline (VS Code / CLI) │
                                    └──────────────┘
```

| 组件 | 在哪 | 作用 | 是否必须 |
|---|---|---|---|
| Hub（`server/`） | 一台能公网访问的 Linux（或局域网机器） | 存数据、发命令、SSE 推送 | ✅ |
| Postgres | 与 Hub 同机 / 已有实例 | 落库 | ✅ |
| bridge（`bridge/`） | 每台 Windows | 采集 Cline 数据、执行远程命令 | ✅ |
| App（`app/`） | Android 手机 | 看会话、发命令、收通知 | ✅ |
| Caddy / 反代 | 服务器 | HTTPS + SSE 不缓冲 | 公网访问时 ✅ |
| hooks + ntfy | Windows + 任意 ntfy 服务 | 任务结束即时通知 | 可选 |

**数据只存在你自己的服务器上**；没有中心服务、没有账号体系，token 就是全部权限。

---

## 1. 准备清单

| 角色 | 需要 | 检查命令 |
|---|---|---|
| 服务器 | Ubuntu 22.04+ / 2 GB 内存 / Docker | `docker --version` |
| 域名 | 可选但强烈建议；没有就用 IP + 端口或内网穿透 | `dig +short hub.example.com` |
| Windows | Windows 10/11、Node ≥ 22.5、Cline（+ CLI 才能下发命令） | `node -v` / `where.exe cline` |
| Android | Android 8+；自己打包还需要 Flutter 3.47 / JDK 17 / Android SDK | `flutter --version` |
| 网络 | 手机能访问 Hub；每台 Windows 也能访问 Hub | 浏览器打开 `/api/v1/health` |

时间：服务器 20 分钟，Windows 每台 10 分钟，手机 5 分钟。

---

## 2. 部署 Hub

### 2.1 最省事：Docker + 同机 Postgres（推荐）

在服务器上：

```bash
# 1) Docker（已装可跳过）
docker --version || curl -fsSL https://get.docker.com | sudo sh

# 2) Postgres：只绑回环，口令自己生成
PGPW=$(openssl rand -hex 20)
echo "$PGPW" | sudo tee /root/pg18-superuser.pass >/dev/null
sudo chmod 600 /root/pg18-superuser.pass
sudo mkdir -p /srv/pgdata
sudo docker run -d --name pg18 --restart unless-stopped \
  -p 127.0.0.1:5432:5432 \
  -e POSTGRES_PASSWORD="$PGPW" \
  -v /srv/pgdata:/var/lib/postgresql \
  postgres:18
```

> `postgres:18` 的卷必须挂 `/var/lib/postgresql`，不是老的 `/var/lib/postgresql/data`，
> 挂错会无限重启。见 [`server-prep.md`](server-prep.md)。

```bash
# 3) 建库 + 最小权限应用角色
APPW=$(openssl rand -hex 16)
sudo docker exec -i pg18 psql -U postgres <<SQL
create role cline_hub_app login password '$APPW';
create database cline_hub owner cline_hub_app;
SQL
```

把仓库放到服务器（`git clone <你的仓库>` 或 `scp` 整个目录），然后：

```bash
cd <仓库>/server
cp .env.example .env
```

编辑 `.env`，至少改这两行（其余保持默认）：

```dotenv
HUB_DATABASE_URL="postgresql://cline_hub_app:上面生成的APPW@127.0.0.1:5432/cline_hub"
HUB_ADMIN_TOKEN="用 openssl rand -hex 32 生成，长度 >= 32"
```

```bash
docker compose build
docker compose run --rm hub node src/migrate.js
docker compose up -d
curl -s http://127.0.0.1:3100/api/v1/health
```

期望：`{"ok":true,"service":"cline-hub",...,"db":{"ok":true,...}}`。

> 不想用 Docker：`npm install && npm run migrate && node src/index.js`，
> 细节见 [`../server/README.md`](../server/README.md)。生产建议 `HUB_AUTO_MIGRATE=0`，
> 迁移显式跑。

### 2.2 HTTPS 反代（Caddy）

```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install -y caddy
```

`/etc/caddy/Caddyfile`：

```caddyfile
hub.example.com {
    encode zstd gzip

    # SSE 必须实时下发，否则事件被攒着，手机顶栏一直「连接中」
    @events path /api/v1/events*
    reverse_proxy @events 127.0.0.1:3100 {
        flush_interval -1
    }

    reverse_proxy 127.0.0.1:3100 {
        transport http {
            read_timeout 0
        }
    }
}
```

```bash
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
sudo systemctl reload caddy
curl -sS https://hub.example.com/api/v1/health
```

前置：DNS A 记录指向服务器、安全组/防火墙放行 80/443，**不要**放行 5432 / 3100。
完整踩坑记录见 [`../deploy/README.md`](../deploy/README.md)（Caddy 日志目录、reload 不生效等）。

### 2.3 没有域名 / 只想先跑通

| 方式 | 做法 | 代价 |
|---|---|---|
| 局域网 | `.env` 设 `HUB_HOST=0.0.0.0`，手机连同一 Wi-Fi，地址 `http://<电脑局域网IP>:3100` | token 明文，别在公共网络用 |
| 内网穿透 | Tailscale / Cloudflare Tunnel / frp 把 3100 或 HTTPS 暴露给手机 | 多一层依赖；仍然建议 HTTPS |
| 只在自己电脑预览 | `http://127.0.0.1:3100` + Android 模拟器 `http://10.0.2.2:3100` | 手机出门就用不了 |

App 目前允许明文 HTTP（Android `usesCleartextTraffic`），所以局域网能直接通；
**一旦有公网地址就切 HTTPS**，并重新轮换 token。

---

## 3. 创建两类 token（只做一次）

在 Hub 所在目录执行：

```bash
# 手机端：role=app，能读全部设备、能下发命令
sudo docker compose exec hub npm run create-device -- --id phone --role app --name "My Phone"

# 每台电脑一个：role=device
sudo docker compose exec hub npm run create-device -- --id my-pc --name "My-PC"
sudo docker compose exec hub npm run create-device -- --id office-pc --name "Office-PC"
```

输出形如：

```
client : my-pc (device) "My-PC"
token  : clh_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

| token 类型 | 给谁 | 能做什么 | 泄露后 |
|---|---|---|---|
| `device` | 每台电脑的 `bridge/config.json` | 只写 / 只读自己的会话、hook、命令 | 只能冒充那一台；轮换该 id 即可 |
| `app` | 手机设置页 | 读**所有**设备的会话与命令、下发 / 取消命令 | 等于整个 Hub 的读权限 + 下发权限，必须立刻轮换 |
| `admin` | 只在服务器 `.env` | 管理 clients、跨设备调试 | 等于服务器控制权，永不下发到客户端 |

**token 只在创建时打印一次**，库里只存 sha256。存进密码管理器，绝不进 git / 截图 / 聊天。

> 同一个 id 再执行一次会轮换 token（旧 token 立即失效），适合「怀疑泄露」时用。
> 删除设备：`DELETE /api/v1/clients/<id>?confirm=1`（级联删该设备的会话 / 命令 / hook）。

---

## 4. 配置 Windows bridge

最短路径（完整字段说明见 [`new-device.md`](new-device.md)）：

```powershell
# 1) 拿代码（或直接拷贝仓库目录）
git clone <你的仓库> C:\cline-hub
cd C:\cline-hub\bridge
copy config.example.json config.json

# 2) 确认前置
node -v                       # >= 22.5
where.exe cline               # 下发命令必须有 CLI
Test-Path "$env:USERPROFILE\.cline\data\db\sessions.db"
```

编辑 `bridge/config.json`：

```json
{
  "hubUrl": "https://hub.example.com",
  "deviceId": "my-pc",
  "deviceToken": "clh_这台电脑的 device token",
  "workspaceWhitelist": ["C:\\Users\\you\\projects"],
  "commands": {
    "enabled": true,
    "runner": "cline",
    "allowModes": ["plan"],
    "defaultWorkspace": "C:\\Users\\you\\projects",
    "cline": {
      "bin": "C:\\Users\\you\\AppData\\Local\\...\\cline.cmd",
      "provider": "你的 provider",
      "model": "你的 model",
      "resume": false
    }
  }
}
```

起 bridge：

```powershell
cd C:\cline-hub\bridge
npm run once          # 先跑一轮，确认能连 Hub
node src/index.js     # 常驻；后台启动用 Start-Process
npm run health
```

> 不要用 `nohup node ... &`（Git Bash 会把终端 shell 一起带走）。
> 后台启动：`Start-Process -WindowStyle Hidden node -ArgumentList 'src/index.js' -WorkingDirectory 'C:\cline-hub\bridge'`。

先只读采集可以把 `commands.enabled` 设 `false`；确认会话能上来后再打开。

---

## 5. 装手机 App

### 方式 A：自己打包（推荐，签名自己掌握）

```bash
cd app
flutter pub get
flutter analyze
flutter test
flutter build apk --release
# → build/app/outputs/flutter-apk/app-release.apk
```

需要 JDK 17+、Android SDK。第一次打包慢（1–3 分钟），之后有缓存。

> 仓库默认的 `release` 构建用的是 **debug 签名**（Flutter 模板行为）：自己用没问题，
> 但公开分发给别人前应换成自己的 keystore，否则换机器重建会签名冲突、必须卸载重装。

### 方式 B：用仓库的发版脚本（顺带生成自更新清单）

```bash
# 先把 app/pubspec.yaml 和 app/lib/src/data/app_version.dart 改成同一版本
node app/scripts/release-apk.mjs \
  --notes "自托管首版" \
  --base-url https://hub.example.com/app
# → app/dist/cline-console-<version>.apk + app/dist/latest.json
```

把 APK 放到服务器的静态目录，并在 Caddy 里加：

```caddyfile
handle_path /app/* {
    root * /var/www/cline-hub/app
    file_server
}
```

把 `latest.json` 放到 Hub 容器能读到的位置（`server/docker-compose.yml` 里
`HUB_APP_RELEASE_FILE` 指向 `/app/releases/latest.json`），App 的「检查更新」就能用。

### 首次启动

1. Hub 地址：`https://hub.example.com`（**不要**带 `/api/v1`）
2. token：上一步的 `app` token
3. 点「测试连接」→ 应显示服务 / DB / token 都正常
4. 进入 App → 右侧菜单「电脑」里能看到电脑（在线状态 / 计数，点一行设为默认）
5. 命令页发 `plan` 命令，观察状态流转

---

## 6. 完整闭环验收（照着打勾）

| # | 检查 | 命令 / 操作 | 期望 |
|---|---|---|---|
| 1 | Hub 活着 | `curl -s https://hub.example.com/api/v1/health` | `ok:true` + `db.ok:true` |
| 2 | 设备已建 | `GET /api/v1/devices`（app token） | 出现 `my-pc` |
| 3 | bridge 活着 | Windows `npm run health` | `service: cline-bridge` |
| 4 | 会话上报 | 电脑上跑一次 Cline 会话，等 5–10 秒 | App 会话页出现它 |
| 5 | 下发命令 | App 命令页选 `my-pc` + 工作目录，发一条 `plan` | `pending → delivered → running` |
| 6 | 执行完成 | 等命令结束 | `done`，有输出 |
| 7 | 命令的会话 | 命令详情点会话 | 能看到这次执行的会话与消息 |
| 8 | 通知（可选） | 开启系统通知 | 命令 / 会话终态弹通知 |

**第 4 步不动**：先看 `bridge/logs/bridge.log` 有没有 `hub health` / 上报错误；
再看 `workspaceWhitelist` 是否把目录排除了。
**第 5 步卡 `pending`**：该机器 `commands.enabled=false` 或 bridge 没在轮询。
**卡 `running`**：cline 在等 stdin / 超时 / bridge 被硬杀，见 [`interruptions.md`](interruptions.md)。

---

## 7. 多台电脑 / 多人使用（重要边界）

### 7.1 自己的多台电脑

- 每台 Windows 一个 **独立 `deviceId` + device token**，配置只改那一台的 `bridge/config.json`。
- Hub 上按 `(deviceId, sessionId)` 存数据，同一台机器上的同名会话不会串。
- App 右侧菜单的「浏览」区在 ≥2 台设备时出现设备 chip（只筛列表，不改默认）；
  「电脑」区能看到在线状态 / 计数，点一行设为默认（P39）。
- 下发命令时明确选设备；`GET /api/v1/devices` 给 App 提供设备列表（ADR-47）。
- 一台机器不想被远程执行：它自己的 `commands.enabled=false`，不影响采集和其它机器。

详细步骤见 [`new-device.md`](new-device.md)。

### 7.2 给朋友 / 团队用

**这个 Hub 是单租户的**：`app` token 能读所有设备的数据、能给所有设备下命令（P19 只隔离
`device` token，不隔离 `app`）。所以：

| 需求 | 推荐做法 |
|---|---|
| 朋友也想用 | **各自部署一套 Hub**（这份文档就是给他看的），不要把 app token 给外人 |
| 家里几台设备、自己一个人 | 一个 app token 即可；每台电脑独立 device token |
| 团队共用一台 Hub | 至少给每人一个 app client，但要讲清楚「彼此能看到全部会话」；敏感项目别放同一 Hub |
| 只想让某人看某台机器 | 当前版本做不到按用户隔离；不要用「发不同 app token」假装隔离 |

如果确实需要多人隔离，正确方向是给 Hub 加「用户 → 设备」授权表（新 ADR），
不是多发几个 token。

### 7.3 轮换与吊销

```bash
# 轮换一台设备的 token（不影响其它设备）
sudo docker compose exec hub npm run create-device -- --id my-pc --name "My-PC"
# 把新 token 填回该电脑的 config.json，重启 bridge

# 彻底移除一台设备（级联删数据）
curl -X DELETE -H "Authorization: Bearer $HUB_ADMIN_TOKEN" \
  "https://hub.example.com/api/v1/clients/my-pc?confirm=1"
```

---

## 8. 升级、备份、迁移

### 升级 Hub

```bash
cd <仓库>
git pull
cd server
docker compose build
docker compose run --rm hub node src/migrate.js
docker compose up -d
curl -s http://127.0.0.1:3100/api/v1/health
```

迁移是幂等的，按文件名顺序只执行一次；上线前先备份：

```bash
sudo docker exec pg18 pg_dump -U postgres cline_hub | gzip > ~/cline_hub-$(date +%F).sql.gz
```

### 升级 bridge

```powershell
cd C:\cline-hub
git pull
cd bridge
npm run stop -- --reason "升级 bridge"     # 先回写执行中的命令，再杀进程树
npm run restart -- --reason "升级 bridge"  # 或手动 Start-Process
npm run health
```

**不要用 `Stop-Process` / `taskkill` 硬杀**：Node 收不到 SIGTERM，手机上的命令会卡「执行中」。
每次主动中断都记一条 [`interruptions.md`](interruptions.md)。

### 迁移服务器

1. 新机装 Docker / Caddy / Postgres；
2. `pg_dump` 旧库 → `psql` 新库；
3. 复制 `server/.env`（**不要进 git**）与 `releases/latest.json`；
4. DNS 切到新 IP，重签证书；
5. 手机 / bridge 的 `hubUrl` 不用改（域名不变）；用 IP 的才需要改。

---

## 9. 安全基线（照做，别省）

1. **HTTPS**：公网只开 80/443；3100 与 5432 只绑回环，安全组不放行。
2. **token 分级**：device 只给电脑，app 只给手机，admin 永不出服务器；库里只有 sha256。
3. **默认最小权限**：`commands.enabled=false` 起步，`allowModes` 先只留 `plan`，
   `workspaceWhitelist` 填绝对路径（空数组 = 不限制）。
4. **`app` token 等于全库读权限**：截图、日志、工单里都不要出现；泄露立刻重建 phone client。
5. **日志含 prompt / 命令输出**：服务器磁盘和日志访问权限要收紧；别把 `bridge/logs` 传公开仓库。
6. **备份加密**：`pg_dump` 里有全部会话内容，别放公开对象存储。
7. **删除即级联**：`DELETE /clients/:id?confirm=1` 会删该设备的会话 / 命令 / hook，不可恢复。
8. **升级后轮换**：如果曾经在明文 HTTP 上用过 token，切 HTTPS 当天重新签发。

---

## 10. 常见故障

| 现象 | 先查 |
|---|---|
| App 一直「连接中」 | Caddy 是否 `flush_interval -1`；`curl -N https://hub/api/v1/events?token=...` 有没有 `: connected` |
| `401 invalid_token` | token 轮换过 / 粘贴错；重新 `create-device` |
| `403 forbidden` | 用 device token 发命令；下发必须是 app token |
| `403 device_mismatch` | device token 读了别的设备；检查 `deviceId` |
| `404` 且 body 空 | 地址带了 `/_h/<前缀>` 或 `/api/v1`；只用根地址 |
| `429 rate_limited` | 触发每 IP 限流；调 `HUB_RATE_LIMIT_*` 或检查是否有循环重试 |
| 设备列表空 | `GET /api/v1/devices` 是否 200；bridge 是否在跑；Hub 是否旧版本（升级后才有此接口） |
| 会话不出现 | `dataDir`；`workspaceWhitelist`；`bridge/logs/bridge.log` |
| 命令一直 `pending` | `commands.enabled`；`allowModes`；bridge 进程 |
| `workspace not allowed` | `workspaceWhitelist`；`npm run check:whitelist` |
| 命令卡 `running` | `npm run ps`；硬杀过则 `npm run reconcile`；看 [`interruptions.md`](interruptions.md) |
| APK 装不上 | 是否同一签名；旧包先卸载；Android 版本 |
| 手机收不到通知 | 系统通知权限；App 设置里的两个开关 |

---

## 11. 一页命令清单（复制用）

```bash
# ---- 服务器 ----
cd <仓库>/server
cp .env.example .env                 # 填 HUB_DATABASE_URL / HUB_ADMIN_TOKEN
docker compose build
docker compose run --rm hub node src/migrate.js
docker compose up -d
curl -s http://127.0.0.1:3100/api/v1/health

sudo docker compose exec hub npm run create-device -- --id phone --role app --name "My Phone"
sudo docker compose exec hub npm run create-device -- --id my-pc --name "My-PC"

# ---- Windows（每台）----
cd C:\cline-hub\bridge
copy config.example.json config.json  # hubUrl / deviceId / deviceToken / 白名单
npm run check:whitelist
npm run once
node src/index.js
npm run health

# ---- 手机 ----
cd app
flutter build apk --release
# 安装后填 https://hub.example.com + app token
```

跑通后，把这份文档和 [`new-device.md`](new-device.md) 一起发给下一个人，他只需要重复
「服务器 → 电脑 → 手机」三步，就能形成自己的闭环。
