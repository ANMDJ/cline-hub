# Cline Console · 服务器准备清单

> 目标机：**Ubuntu 24.04 LTS**（域名 `littlewish.top`）
> 记录时间：2026-10-31
> 用途：按顺序复制执行即可把一台空机器准备好；**所有命令都不含真实口令**（口令在 M1 部署时注入）。

---

## 0. 一次性决策（已定）

| 项 | 决定 | 理由 |
|---|---|---|
| 子域名 | `kids` / `hub` / `ntfy` .littlewish.top | 与 kids_points 项目共用一台机、一套 Caddy |
| HTTPS | Caddy 自动签发 | 零配置续期，WebSocket 原生支持 |
| 数据库 | Docker `postgres:18` | 与本地开发 18.6 对齐（见 kids 的 `06-w0-report.md`） |
| 库隔离 | `kids_points` / `cline_hub` 两个库 | 两项目互不干扰，可独立备份/迁移 |
| 应用端口 | kids `3000`、hub `3100`、ntfy `2586`、pg `5432` | **全部只绑 127.0.0.1**，对外仅 80/443 |
| Node | 服务器不装 | 服务都在 Docker 里构建运行 |
| Flutter | 服务器不装 | Web 产物在本机构建后 `scp` 上传 |

---

## 1. 域名解析（域名商控制台加 A 记录）

| 主机记录 | 类型 | 值 | 用途 |
|---|---|---|---|
| `kids` | A | 服务器公网 IPv4 | Flutter Web + `/api` 反代后端 |
| `hub` | A | 服务器公网 IPv4 | Cline Hub（REST + WebSocket） |
| `ntfy` | A | 服务器公网 IPv4 | 自建推送 |

> ⚠️ **备案**：服务器在中国大陆 ⇒ 80/443 必须完成 ICP 备案，否则被阻断。境外服务器无需备案但延迟高。

解析生效自检（本地）：

```bash
dig +short kids.littlewish.top
dig +short hub.littlewish.top
dig +short ntfy.littlewish.top
```

三条都要返回服务器 IP，才能申请证书（Caddy 首次启动会去校验）。

---

## 2. 服务器规格

| 项 | 建议 |
|---|---|
| 系统 | Ubuntu 24.04 LTS x86_64 |
| CPU/内存 | 2 核 4 GB 起（PG + 2 个 Node 服务 + Caddy + ntfy） |
| 磁盘 | 40 GB+ SSD |
| 网络 | 公网 IPv4，安全组放行 `22/80/443` |
| 时区 | Asia/Shanghai |

---

## 3. 组件清单

| 组件 | 安装方式 | 用途 |
|---|---|---|
| Docker Engine + Compose Plugin | 官方 apt 源 | 跑 pg / kids-api / cline-hub / ntfy |
| Caddy | 官方 apt 源 | 自动 HTTPS + 三子域反代 |
| PostgreSQL 18 | Docker 镜像 | 两个业务库 |
| ufw | Ubuntu 仓库 | 防火墙 |
| fail2ban | Ubuntu 仓库 | SSH 爆破防护 |
| git / curl / jq / unzip / htop | Ubuntu 仓库 | 基础工具 |

**不需要安装**：Node.js、Flutter SDK、Nginx、Certbot。

---

## 4. 系统初始化（按顺序执行）

### 4.1 基础包 + 时区

```bash
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y ca-certificates curl gnupg git ufw fail2ban jq unzip htop
sudo timedatectl set-timezone Asia/Shanghai
```

### 4.2 安装 Docker（官方源）

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
docker --version && docker compose version
```

分配 `deploy` 用户使用 docker 的权限（在 4.4 建完用户后再执行一次 `usermod`，这里先装好）。

### 4.3 Docker 守护进程日志上限（防磁盘被日志吃满）

```bash
sudo tee /etc/docker/daemon.json >/dev/null <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
JSON
sudo systemctl restart docker
```

> 国内机器拉镜像慢时，按云厂商文档在 `daemon.json` 里追加 `"registry-mirrors": ["https://<你的加速地址>"]` 后重启 docker。

### 4.4 安装 Caddy（官方源）

```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install -y caddy
caddy version
```

### 4.5 部署用户 + 目录

```bash
sudo adduser --disabled-password --gecos "" deploy
sudo usermod -aG docker deploy
sudo mkdir -p /opt/kids/backend /opt/kids/data/pg /opt/cline-hub/server /opt/ntfy/etc /opt/ntfy/cache /opt/backups /srv/kids-web
sudo chown -R deploy:deploy /opt /srv/kids-web
sudo chmod -R a+rX /srv/kids-web
```

### 4.6 SSH 密钥登录（**顺序不能反，否则会把自己锁在外面**）

本机 Windows 生成密钥：

```powershell
ssh-keygen -t ed25519 -C "littlewish-deploy" -f $env:USERPROFILE\.ssh\littlewish_deploy
Get-Content $env:USERPROFILE\.ssh\littlewish_deploy.pub
```

服务器上把公钥写入 `deploy` 用户：

```bash
sudo mkdir -p /home/deploy/.ssh
sudo tee -a /home/deploy/.ssh/authorized_keys >/dev/null   # 粘贴公钥，Ctrl+D 结束
sudo chown -R deploy:deploy /home/deploy/.ssh
sudo chmod 700 /home/deploy/.ssh && sudo chmod 600 /home/deploy/.ssh/authorized_keys
echo 'deploy ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/90-deploy
sudo chmod 440 /etc/sudoers.d/90-deploy
```

**先另开一个终端验证 `ssh -i ~/.ssh/littlewish_deploy deploy@<IP>` 免密能登录成功**，再执行加固：

```bash
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf >/dev/null <<'SSHD'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
MaxAuthTries 3
SSHD
sudo sshd -t && sudo systemctl reload ssh
```

### 4.7 防火墙

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow 80,443/tcp
sudo ufw --force enable
sudo ufw status verbose
```

> 云厂商**安全组**也要放行 22/80/443；ufw 与安全组是两道独立开关。

---

## 5. 数据库（Postgres 18）

### 5.1 `/opt/kids/docker-compose.yml`（只放 pg，先起库）

```yaml
services:
  postgres:
    image: postgres:18
    container_name: pg
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: <超级用户强口令>
      TZ: Asia/Shanghai
    ports:
      - "127.0.0.1:5432:5432"
    volumes:
      # PG 18 官方镜像的 PGDATA 变为 /var/lib/postgresql/18/docker，故挂父目录
      - /opt/kids/data/pg:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
```

```bash
cd /opt/kids && docker compose up -d postgres
docker exec -it pg psql -U postgres -v ON_ERROR_STOP=1 <<'SQL'
CREATE DATABASE kids_points OWNER postgres;
CREATE ROLE cline_hub_app LOGIN PASSWORD '<cline_hub 应用强口令>';
CREATE DATABASE cline_hub OWNER cline_hub_app;
SQL
```

> `kids_points_app` 角色**不要手工建**：由 kids 仓库的 `prisma/sql/900_ledger_revoke.sql` 创建（只建角色、不设口令），口令由 `901_set_app_password.sql` 注入 —— 这是项目已定的 D7 决策。

### 5.2 两个库的连接串（写进各自 `.env`，不进 git）

| 变量 | 值 |
|---|---|
| kids `DATABASE_URL` | `postgresql://kids_points_app:<口令>@127.0.0.1:5432/kids_points?schema=public` |
| kids `MIGRATION_DATABASE_URL` | `postgresql://postgres:<超级口令>@127.0.0.1:5432/kids_points?schema=public` |
| hub `DATABASE_URL` | `postgresql://cline_hub_app:<口令>@127.0.0.1:5432/cline_hub` |

---

## 6. 服务编排（`/opt/kids/docker-compose.yml` 追加）

```yaml
  kids-api:
    build: /opt/kids/backend
    container_name: kids-api
    restart: unless-stopped
    env_file: /opt/kids/backend/.env
    environment:
      TZ: Asia/Shanghai
    ports:
      - "127.0.0.1:3000:3000"
    depends_on:
      postgres:
        condition: service_healthy

  cline-hub:
    build: /opt/cline-hub/server
    container_name: cline-hub
    restart: unless-stopped
    env_file: /opt/cline-hub/.env
    environment:
      TZ: Asia/Shanghai
    ports:
      - "127.0.0.1:3100:3100"
    depends_on:
      postgres:
        condition: service_healthy
```

> 后端镜像的 `Dockerfile` 在 M1 由我生成（kids 仓库当前**没有** Dockerfile / compose）。

---

## 7. Caddy 反代（`/etc/caddy/Caddyfile`）

```caddyfile
{
    email admin@littlewish.top
}

kids.littlewish.top {
    encode zstd gzip
    root * /srv/kids-web

    @api path /api/*
    handle @api {
        reverse_proxy 127.0.0.1:3000
    }
    handle {
        try_files {path} /index.html
        file_server
    }

    header {
        X-Content-Type-Options nosniff
        Referrer-Policy strict-origin-when-cross-origin
    }
}

hub.littlewish.top {
    encode zstd gzip
    reverse_proxy 127.0.0.1:3100
}

ntfy.littlewish.top {
    encode zstd gzip
    reverse_proxy 127.0.0.1:2586
}
```

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
sudo journalctl -u caddy -f
```

> `hub` 的 `/ws` WebSocket 无需额外配置；Caddy 自动升级并转发。首次访问会触发证书申请，**前提是 DNS 已生效且 80/443 可达**。

---

## 8. 自建 ntfy（推送）

### 8.1 `/opt/ntfy/etc/server.yml`

```yaml
base-url: "https://ntfy.littlewish.top"
listen-http: ":80"
cache-file: "/var/cache/ntfy/cache.db"
auth-file: "/var/cache/ntfy/user.db"
auth-default-access: "deny-all"
behind-proxy: true
attachment-cache-dir: "/var/cache/ntfy/attachments"
```

### 8.2 `/opt/ntfy/docker-compose.yml`

```yaml
services:
  ntfy:
    image: binwiederhier/ntfy
    container_name: ntfy
    restart: unless-stopped
    command: serve
    environment:
      TZ: Asia/Shanghai
    volumes:
      - /opt/ntfy/etc:/etc/ntfy
      - /opt/ntfy/cache:/var/cache/ntfy
    ports:
      - "127.0.0.1:2586:80"
```

```bash
cd /opt/ntfy && docker compose up -d
docker exec -it ntfy ntfy user add --role=admin admin
docker exec -it ntfy ntfy access everyone "cline-<32位随机串>" wo
docker exec -it ntfy ntfy token add --label=bridge --expires=never admin
```

手机端：安装 ntfy App → 服务器填 `https://ntfy.littlewish.top` → 登录 `admin` → 订阅 `cline-<32位随机串>`。

> `auth-default-access: deny-all` ⇒ 未认证匿名**不能**发布；bridge 用 token 发。

---

## 9. kids 后端部署（服务器上）

```bash
cd /opt/kids/backend
cp .env.example .env
# 编辑 .env（**只填生产值，不要提交 git**）：
#   NODE_ENV=production
#   PORT=3000
#   DATABASE_URL=postgresql://kids_points_app:<口令>@127.0.0.1:5432/kids_points?schema=public
#   MIGRATION_DATABASE_URL=postgresql://postgres:<超级口令>@127.0.0.1:5432/kids_points?schema=public
#   AUTH_DEVICE_ID_FALLBACK=0
#   CORS_ALLOWED_ORIGINS=https://kids.littlewish.top
#   PUBLIC_BASE_URL=https://kids.littlewish.top
#   WECHAT_MP_APPID=... / WECHAT_MP_SECRET=...

npm ci
npx prisma migrate deploy
npm run seed
psql "$MIGRATION_DATABASE_URL" -v ON_ERROR_STOP=1 -f prisma/sql/900_ledger_revoke.sql
APP_DB_PASSWORD='<kids_points_app 强口令>' \
  psql "$MIGRATION_DATABASE_URL" -v ON_ERROR_STOP=1 \
       -v app_password="$APP_DB_PASSWORD" \
       -f prisma/sql/901_set_app_password.sql
npm run db:verify
npm run build
```

> 每条 `psql` 必须带 `-v ON_ERROR_STOP=1`：不带时脚本内 `RAISE EXCEPTION` 的退出码仍是 0（D12 假绿，已在 psql 18.6 实测）。

### Flutter Web（本机构建 → 上传）

```powershell
flutter build web --release --dart-define=KP_API_BASE_URL=https://kids.littlewish.top
scp -i $env:USERPROFILE\.ssh\littlewish_deploy -r build/web/* deploy@<服务器IP>:/srv/kids-web/
```

### 微信小程序

小程序**不能**部署到服务器，只能上传到微信公众平台；并在微信后台把 `https://kids.littlewish.top` 加入 request 合法域名（依赖备案）。

---

## 10. 开服验收

```bash
dig +short hub.littlewish.top
curl -I https://kids.littlewish.top
curl -s -o /dev/null -w '%{http_code}\n' https://hub.littlewish.top/api/v1/health
curl -s https://ntfy.littlewish.top/v1/health
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
sudo ss -lntp | grep -E ':(80|443|3000|3100|2586|5432)'
```

预期：`3000/3100/2586/5432` 只监听 `127.0.0.1`；对外只有 `80/443`。

---

## 11. 备份

```bash
cat > /opt/backups/dump.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
D=$(date +%F)
docker exec pg pg_dump -U postgres -Fc kids_points > /opt/backups/kids_$D.dump
docker exec pg pg_dump -U postgres -Fc cline_hub  > /opt/backups/cline_$D.dump
find /opt/backups -name '*.dump' -mtime +7 -delete
SH
chmod +x /opt/backups/dump.sh
( crontab -l 2>/dev/null; echo "30 3 * * * /opt/backups/dump.sh >> /opt/backups/dump.log 2>&1" ) | crontab -
```

---

## 12. 常见故障

| 现象 | 原因 | 处理 |
|---|---|---|
| Caddy 拿不到证书 | DNS 未生效 / 80 被安全组挡 | `dig` 确认 A 记录；云控制台放行 80 |
| `hub` 502 | 容器未起或端口没绑 | `docker ps`、`docker logs cline-hub` |
| WebSocket 立刻断开 | 中间有代理未转发 Upgrade | 直连 Caddy；检查响应头 `101 Switching Protocols` |
| ntfy 401 | 匿名被 deny-all | 用 token 或登录用户发布 |
| kids 启动即失败 | `AUTH_DEVICE_ID_FALLBACK=1` 且 `NODE_ENV=production` | 显式写 `0`（fail-closed 设计） |
| psql 报「角色不存在」 | 跳过了 900 | 先跑 `900_ledger_revoke.sql` 再跑 901 |
