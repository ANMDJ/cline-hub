# 部署 runbook（82.157.153.22 / littlewish.top）

> DNS 已就绪：`kids`、`hub`、`ntfy` 三个 A 记录都指向 `82.157.153.22`（2026-10-31 实测）。
> 下面每一步都可以重复执行，失败不会留半截状态。

## 0. 两个只能在控制台完成的前置

| # | 事项 | 状态 |
|---|---|---|
| 1 | 放行 **80 / 443**（22 已通） | ✅ 已完成（2026-10-31 复测：80/443 由 TIMEOUT 变 ECONNREFUSED，说明外网可达、只是还没进程监听） |
| 2 | 确认 SSH 密钥可用 | ✅ 已完成，见下 |

> 目标机：Ubuntu 22.04.5 LTS / 2 vCPU / 3.7G 内存 / 89G 盘（4.6G 已用）/ 时区 Asia/Shanghai / `sudo` 免密。

SSH 登录（已实测可用）：

```bash
# 私钥是本机 Downloads 里那把 RSA 私钥
cp <下载目录>/kids.pem ~/.ssh/kids.pem && chmod 600 ~/.ssh/kids.pem
ssh -i ~/.ssh/kids.pem ubuntu@82.157.153.22
```

`root@` / `lighthouse@` 都是 `Permission denied (publickey)`，只有 `ubuntu@` 可用；
`sudo` 免密，所以后续命令加 `sudo` 即可，不用纠结 docker 用户组。


## 1. 基线检查（拿到 shell 后第一件事）

```bash
whoami; uname -a; lsb_release -ds
df -h /; free -m | head -2; timedatectl | head -3
ss -lntp | grep -E ':(80|443|3000|3100|5432|2586)\b' || echo 'no listeners'
docker --version; docker compose version; caddy version
sudo -n true && echo 'sudo ok'
```

**先看清再动手**：如果 3000/5432 已经被 kids_points 占用，就别重建，直接复用
（`hub` 只是同一个 Postgres 里的另一个库）。

## 2. 装 Docker + Caddy（缺什么装什么）

```bash
# Docker（官方脚本，约 1 分钟）
docker --version || curl -fsSL https://get.docker.com | sudo sh

# ⚠️ 腾讯云国内机直连 Docker Hub 必挂：dial tcp ...registry-1.docker.io:443 i/o timeout
# 用腾讯云内网镜像源（只有腾讯云主机能解析，速度最快）
echo '{"registry-mirrors":["https://mirror.ccs.tencentyun.com"]}' | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker
sudo docker pull hello-world >/dev/null && echo 'registry ok'

# Caddy（官方 apt 源，自带 systemd 单元）
if ! command -v caddy >/dev/null; then
  sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | sudo tee /etc/apt/sources.list.d/caddy-stable.list
  sudo apt update && sudo apt install -y caddy
fi
caddy version && systemctl is-active caddy
```

> 实测版本：Docker 29.9.2 + Compose v5.6.1、Caddy 2.11.7。
> 备选镜像源（腾讯内网挂了再试）：`https://docker.1ms.run`、`https://docker.xuanyuan.me`、`https://hub.rat.dev`。
```

## 3. Postgres：建库 + 建角色

复用已有 `postgres:18` 容器（端口只绑 127.0.0.1）；没有就起一个：

```bash
sudo docker ps --format '{{.Names}}\t{{.Image}}\t{{.Ports}}' | grep -i postgres
# 没有的话（口令自己生成，别用示例）：
#   PGSUPER=$(openssl rand -hex 24); echo "$PGSUPER" | sudo tee /root/pg18-superuser.pass; sudo chmod 600 /root/pg18-superuser.pass
#   sudo mkdir -p /srv/pgdata
#   sudo docker run -d --name pg18 --restart unless-stopped -p 127.0.0.1:5432:5432 \
#     -e POSTGRES_PASSWORD="$PGSUPER" -v /srv/pgdata:/var/lib/postgresql postgres:18
```

> ⚠️ **postgres:18 的卷必须挂 `/var/lib/postgresql`**（不是老的 `/var/lib/postgresql/data`）。
> 镜像里 `PGDATA=/var/lib/postgresql/18/docker`，挂错目录容器会无限重启并报
> `there appears to be PostgreSQL data in: /var/lib/postgresql/data (unused mount/volume)`。
> 踩坑记录见 <https://github.com/docker-library/postgres/pull/1259>。


建库与最小权限角色（口令自己生成，别用示例）：

```bash
PW=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
docker exec -i pg18 psql -U postgres <<SQL
create role cline_hub_app login password '$PW';
create database cline_hub owner cline_hub_app;
SQL
echo "HUB_DATABASE_URL=postgresql://cline_hub_app:$PW@127.0.0.1:5432/cline_hub" >> /tmp/hub.env.part
```

## 4. 上传服务端并配置

本机执行（打包时排除 `node_modules` / `logs` / `.env`，本机的库口令和 token 不上服务器）：

```bash
cd <仓库>
tar --exclude=node_modules --exclude=logs --exclude=.env -czf /tmp/server.tgz server deploy
scp /tmp/server.tgz <user>@82.157.153.22:/tmp/
```

服务器上：

```bash
sudo mkdir -p /srv/cline-hub && sudo chown "$USER" /srv/cline-hub
tar -xzf /tmp/server.tgz -C /srv/cline-hub --strip-components=0
cd /srv/cline-hub/server
cp .env.example .env
# 填三项：HUB_DATABASE_URL（第 3 步生成）、HUB_ADMIN_TOKEN=$(openssl rand -hex 24)、HUB_LOG_LEVEL=info
chmod 600 .env
```

## 5. 迁移 + 起服务

```bash
cd /srv/cline-hub/server
# 国内构建装依赖很慢，用 npmmirror
sudo docker compose build --build-arg NPM_REGISTRY=https://registry.npmmirror.com
sudo docker compose run --rm hub node src/migrate.js     # 显式迁移，生产不开 AUTO_MIGRATE
sudo docker compose up -d
sudo docker compose logs --tail=30 hub
curl -s http://127.0.0.1:3100/api/v1/health
```

期望：`{"ok":true,...,"db":{"ok":true,...}}`。报 `ECONNREFUSED 127.0.0.1:5432` 说明 Postgres 没监听回环，
把第 3 步的容器 `-p 127.0.0.1:5432:5432` 补上即可。

## 6. Caddy：签证书 + 反代

```bash
sudo cp /srv/cline-hub/deploy/Caddyfile /etc/caddy/Caddyfile
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
sudo systemctl reload caddy
sleep 5; sudo journalctl -u caddy -n 30 --no-pager
curl -s https://hub.littlewish.top/api/v1/health
```

- 证书签发失败通常是 80/443 没放行，或 DNS 还没生效（`dig +short hub.littlewish.top`）。
- `curl` 能拿到 JSON 但很短、没有 SSE —— 别慌，`/events` 没 token 本来就 401。
- **Caddy 日志路径必须写 `/var/lib/caddy/hub.log`**：caddy.service 带 `ProtectSystem=full`，
  写 `/var/log/caddy/*` 会 `permission denied` 并让 reload 失败（`curl` 直接空响应）。
- 线上 Caddyfile 目前**只启用了 `hub.littlewish.top`**，`kids` / `ntfy` 段落先注释着，
  等各自服务上线再放开（否则 Caddy 会去签本用不上的证书）。

## 7. 建设备并把 bridge 切到线上

```bash
cd /srv/cline-hub/server
docker compose exec hub npm run create-device -- --id localone --name "LocalOne-Windows"
docker compose exec hub npm run create-device -- --id phone --role app --name "Pixel-8"
```

两个 token 各打印一次，抄走。然后在本机改 `bridge/config.json`：

```json
{
  "hubUrl": "https://hub.littlewish.top",
  "deviceId": "localone",
  "deviceToken": "clh_<新 token>"
}
```

重启 bridge，看 `bridge/logs` 里 outbox 从 N 掉到 0。

## 8. 验收（本机跑，不在服务器上跑）

```bash
cd <仓库>/server
HUB_SMOKE_BASE=https://hub.littlewish.top \
  node scripts/smoke.mjs --token-device <device token> --token-app <app token>
```

20 项全绿即上线完成（health / 401 / 403 / 分页 / 详情 / 搜索 / 命令闭环 / SSE）。
若最后一条 `SSE` 报 WARN，是 Caddy 缓冲没关 —— 检查 `Caddyfile` 里 `flush_interval -1` 那段。

## 9. 上线后的日常

```bash
# 备份（每天 3:20，保留 14 天）
echo '20 3 * * * docker exec pg18 pg_dump -U cline_hub_app cline_hub | gzip > /srv/backup/cline_hub_$(date +\%F).sql.gz' | sudo tee /etc/cron.d/cline-hub-backup
sudo mkdir -p /srv/backup
find /srv/backup -name 'cline_hub_*.sql.gz' -mtime +14 -delete

# 防火墙：只留 22/80/443
sudo ufw allow 22/tcp && sudo ufw allow 80,443/tcp && sudo ufw enable

# 巡检
docker compose -f /srv/cline-hub/server/docker-compose.yml ps
docker compose -f /srv/cline-hub/server/docker-compose.yml logs --tail=50 hub
curl -s https://hub.littlewish.top/api/v1/health
```

## 回滚

```bash
cd /srv/cline-hub/server
docker compose down                      # 只停 hub，数据在 Postgres 里
git log --oneline -5 2>/dev/null || true # 代码回退到上一个 tag
docker compose up -d --build
```

本机侧把 `bridge/config.json` 的 `hubUrl` 改回 `http://127.0.0.1:3100` 即可立刻恢复离线可用状态
（bridge 的 outbox 会攒着，等 Hub 回来再补传）。

## 10. 实际部署记录（2026-10-31 完成）

| 项 | 实际值 |
|---|---|
| 入口 | `https://hub.littlewish.top`（Let's Encrypt 证书已签发，TLS 校验通过） |
| 代码位置 | `/srv/cline-hub/{server,deploy}`（属主 `ubuntu`） |
| Hub 容器 | `cline-hub`，`network_mode: host`，监听 `127.0.0.1:3100`，`restart` 由 compose 管理 |
| 数据库 | `pg18` 容器（`postgres:18`），`127.0.0.1:5432`，库 `cline_hub`，角色 `cline_hub_app`，卷 `/srv/pgdata` |
| 密钥文件 | 超管口令 `/root/pg18-superuser.pass`；应用口令与 admin token 在 `/srv/cline-hub/server/.env`（`600`） |
| Caddy | `/etc/caddy/Caddyfile`，日志 `/var/lib/caddy/hub.log`，`/events` 段 `flush_interval -1` |
| 设备/应用 | `localone`（device）、`phone`（app）；token 只打印一次，本机存在 `.secrets/*.token.txt`（已 gitignore） |

验收结果：

- 服务端 `curl https://hub.littlewish.top/api/v1/health` → `{"ok":true,"db":{"ok":true,...}}`
- bridge 切线上后 `--once` 三轮把 59 条历史会话全部补传：`sessions=59 / hooks=1`
- 本机跑 `HUB_SMOKE_BASE=https://hub.littlewish.top node scripts/smoke.mjs ...` → **20/20 通过**（含 SSE 推送）
- 手机 → Windows 远程命令闭环实测：`POST /commands`（app token）→ 6 秒内 bridge 执行 → `status=done`，
  `resultText` 为 PowerShell 输出（详见根目录 `README.md` 的「远程命令（bridge 执行器）」一节）

尚未启用（后续里程碑）：`ntfy.littlewish.top`、`kids.littlewish.top` 两个反代段落，以及 Flutter App。

