# Cline Console

自建「Cline 控制台」：Windows 端采集 VS Code Cline 插件 + CLI 的会话结果与命令，
经 Hub 落库并推送到 Android，同时支持从手机下发远程命令回 Windows 执行。

## 组成

> 仓库根目录：`C:\Users\alice\.cline\data\workspaces\chat\cline-hub`（与 `kids_points_app` 同级）

| 模块 | 位置 | 说明 |
|---|---|---|
| Hooks | `hooks/` → `%USERPROFILE%\Documents\Cline\Hooks\` | Cline 全局钩子，任务结束/失败/中断时推送 |
| Bridge | `bridge/` | Windows 常驻进程：收 Hook、增量读 `sessions.db`、上报 Hub、执行远程命令 |
| Hub | `server/` | Ubuntu 上的接收端：REST + SSE + Postgres（本机已联调通过） |
| Site | `site/` | 开源落地页（纯静态，Caddy `file_server` 直出，无构建） |
| App | `app/` | Flutter Android 客户端（Web 仅预览）：会话 / 命令 / 动态 + SSE |

## 数据流

1. **实时**：Cline hook → `_notify.ps1` → ntfy（手机立刻收到）+ `127.0.0.1:3210/hook`（bridge 入库）
2. **回溯**：bridge 轮询 `%USERPROFILE%\.cline\data\db\sessions.db`（`updated_at` 水位线）
   → 读同目录 `messages.json` → 拍平成逐条消息（用户原话 / 正文 / 命令过程）增量上报 Hub
   → 详情页按 `seq` 增量续拉，长会话也不会一次拉几 MB
3. **远程命令**：App → Hub `POST /api/v1/commands`（可带 `sessionId`）
   → bridge 轮询 `/api/v1/commands/pending` → 交给 `cline` CLI 真正进会话
     （带 `sessionId` 用 `--id` 接续，否则 `-c <workspace>` 新开；plan=`-p`，act=`--auto-approve true`）
   → `PATCH /api/v1/commands/:id` 回写 running/done/failed + 输出
4. **下行通知**：手机保持一条 `GET /api/v1/events`（SSE），新会话/新命令即时到达；断线时退化为轮询


## 端口

| 端口 | 归属 | 绑定 |
|---|---|---|
| 3210 | bridge hook server | 127.0.0.1 |
| 3100 | Hub | 127.0.0.1（Caddy 反代） |
| 3000 | kids_points API | 127.0.0.1（Caddy 反代 /api） |
| 2586 | ntfy | 127.0.0.1（Caddy 反代 ntfy.littlewish.top） |

## 当前入口（2026-10-31 起：备案拦截期间）

`hub.littlewish.top` 未备案，部署约 35 分钟后被腾讯云阻断，实测证据：

| 访问方式 | 结果 |
|---|---|
| `https://hub.littlewish.top` | TLS 握手被重置（TCP 能连、证书正常，握手阶段被掐） |
| `http://hub.littlewish.top` | `302` → `https://dnspod.qcloud.com/static/webblock.html?d=hub.littlewish.top`（未备案拦截页） |
| `http://82.157.153.22/` | 正常到达 Caddy（**按 IP 访问不在拦截范围**），但只提供静态落地页，API 已关闭 |

**2026-11-01 起改走 `:8443` + 现有 Let's Encrypt 证书**（443 按 SNI 被重置，8443 未被拦）：

```
Hub 入口   https://hub.littlewish.top:8443          # 不带 /_h/<前缀>
bridge     bridge/config.json → hubUrl = 上面这个（已是）
smoke      HUB_SMOKE_BASE=https://hub.littlewish.top:8443 node server/scripts/smoke.mjs ...
```

IP 明文的 `/_h/<前缀>` 入口 **已从 Caddyfile 删除**（现在 404），`prefix 当口令` 的设计随之退役；
`.secrets/hub-http-prefix.txt` 只作历史留档（见同目录 `RETIRED.md`）。

兜底配套（已生效）：

- Caddy 只在该前缀下反代（`uri strip_prefix` + `flush_interval -1` 保 SSE），其他路径一律 `404`；
- Hub 每 IP 令牌桶限流（默认 120 突发 / 每秒恢复 5），超限 `429`；
- 可选 `HUB_ALLOW_IPS`（CIDR 白名单），默认留空（手机流量 IP 会变），本机回环永远放行。

> ⚠️ 明文 HTTP 意味着 token 在链路上可被嗅探到。备案下来后立刻：删掉 `deploy/Caddyfile` 里的 IP 兜底块 →
> `systemctl reload caddy` → 客户端 `hubUrl` 换回 `https://hub.littlewish.top` → **轮换 device/app token**。

## 网站（开源落地页）

`site/` 是纯静态单页（HTML + CSS + 90 行 JS，无构建、无 CDN 依赖），服务器上由 Caddy `file_server` 直出，
不引入 nginx：

| 地址 | 状态 |
|---|---|
| `http://82.157.153.22/` | ✅ 静态落地页（按 IP 访问不受备案拦截） |
| `https://hub.littlewish.top:8443/api/...` | ✅ **Hub API 唯一入口**（HTTPS，token 不再明文） |
| `http://82.157.153.22/_h/<前缀>/api/...` | ❌ 2026-11-01 起已关闭（404） |
| `https://littlewish.top` / `https://www.littlewish.top` | ⏳ 等 DNS A 记录 + 备案；`deploy/Caddyfile` 里已写好注释段，取消注释即可 |

更新站点（只发包内 5 个文件，`README`/`check-site.mjs` 不上服务器）：

```bash
tar czf /tmp/site.tgz -C site index.html styles.css app.js favicon.svg robots.txt
scp /tmp/site.tgz ubuntu@82.157.153.22:/tmp/
ssh ubuntu@82.157.153.22 'sudo tar -xzf /tmp/site.tgz -C /var/www/cline-hub \
  && sudo chown -R caddy:caddy /var/www/cline-hub && sudo rm -f /tmp/site.tgz'
```

自检：`node site/check-site.mjs`（标签配对 / CSS 括号 / 引用文件 / 锚点 id）。
发布前把 `site/index.html` 里 4 个 `data-todo="repo"` 的 `<a href="https://github.com/">` 换成真实仓库地址。
运行手册见 `site/README.md` 与 `deploy/README.md` §12。


## App（M2b）

Flutter 客户端在 `app/`，Android 为主，Web 只作桌面预览（没有 SSE，退化成 6s 轮询）。

```bash
cd app
flutter pub get
flutter run -d android          # 真机
flutter run -d chrome           # 桌面预览
flutter test                    # 19 个用例：模型 / 状态层 / 页面
flutter build apk --release
```

首次启动进向导，填 Hub 地址（`https://hub.littlewish.top:8443`）和 **app 角色**的 token
（`npm run create-device -- --id phone --role app --name Pixel`）。三个 Tab：

| Tab | 内容 |
|---|---|
| 会话 | 搜索 + 游标无限翻页；详情有结果全文、执行过的命令、耗时 |
| 命令 | 下发 `plan/act/yolo`、盯 `pending→delivered→running→done`、直接读输出 |
| 动态 | hook 事件流（任务开始/结束/中断），比会话采集更快到手机 |

实现上的取舍写在 `app/README.md` 与 `docs/decisions.md` ADR-14。
两个必须知道的坑：**下发命令必须是 app 角色**（device token 会 403）；
**当前是明文 HTTP**，所以 Android 开了 `usesCleartextTraffic`，切 HTTPS 后要删掉并轮换 token。


## 里程碑

| 阶段 | 内容 | 状态 |
|---|---|---|
| M0 | Hook 脚本 + ntfy 通知 | ✅ 完成 |
| M1 | bridge 采集器 + Hub 服务 + 部署 | ✅ 完成（smoke 20/20；域名被备案拦截后改走 IP 前缀入口，见上节） |
| M2a | 远程命令通道（bridge 执行器） | ✅ 完成（App→Hub→bridge→PowerShell→回写，实测 6s 闭环） |
| M2b | Flutter App（会话列表/命令执行） | ✅ 完成（三 Tab + SSE 实时 + 下发命令；`flutter test` 19/19） |


## 快速开始（本机）

```powershell
# 1. 配置推送（已生成默认值）
notepad $env:USERPROFILE\.cline\notify.config.json

# 2. 起 bridge
cd C:\Users\alice\.cline\data\workspaces\chat\cline-hub\bridge
node src/index.js

# 3. 自检
curl http://127.0.0.1:3210/health
```

### Hub 本机联调

```powershell
cd C:\Users\alice\.cline\data\workspaces\chat\cline-hub\server
copy .env.example .env      # 填 HUB_DATABASE_URL / HUB_ADMIN_TOKEN
npm install
npm run migrate
npm run create-device -- --id localone --name "LocalOne-Windows"    # 打印一次 token
npm run create-device -- --id phone --role app --name "Pixel-8"

# 后台常驻：不要用 bash 的 `nohup ... &`（会把终端 shell 一起带走）
Start-Process -WindowStyle Hidden node -ArgumentList 'src/index.js' -WorkingDirectory $PWD
curl http://127.0.0.1:3100/api/v1/health
```

把打印出的 token 分别写进 `bridge/config.json`（`hubUrl` / `deviceId` / `deviceToken`）和 App 设置页。
接口约定见 [`docs/api.md`](docs/api.md)，上线步骤见 [`deploy/README.md`](deploy/README.md)。

## 远程命令（bridge 执行器）

bridge 每 `pollIntervalMs` 轮询 `/api/v1/commands/pending`（服务端 `FOR UPDATE SKIP LOCKED` 认领，多开也不会重复执行），
拿到任务后 → `PATCH running` → 本地跑 → `PATCH done/failed` 回写输出。

`commands.runner` 决定「App 发来的一句话」怎么落地，默认交给 Cline CLI：

```json
"commands": {
  "enabled": false,
  "runner": "cline",
  "template": "{prompt}",
  "shell": "powershell",
  "allowModes": ["plan"],
  "workspaceWhitelist": ["C:\\Users\\<你>\\.cline\\data\\workspaces\\chat\\cline-hub"],
  "defaultWorkspace": "C:\\Users\\alice\\projects",
  "timeoutMs": 600000,
  "batchSize": 3,
  "cline": {
    "bin": "C:\\\\Users\\\\alice\\\\AppData\\\\Local\\\\Author Software\\\\nvm\\\\installs\\\\v26.10.0\\\\cline.cmd",
    "planArgs": ["-p"],
    "actArgs": ["--auto-approve", "true"],
    "extraArgs": [],
    "resume": true,
    "timeoutMs": 1800000
  }
}
```

| 字段 | 说明 |
|---|---|
| `enabled` | 总开关；false 时命令一直留在 `pending`，不会被执行 |
| `runner` | `cline`（config.json 里的取值，真正进 Cline 会话）/ `shell`（把 prompt 当脚本跑） |
| `template` | 仅 `runner="shell"` 时生效，支持 `{prompt}` / `{mode}` / `{workspace}` |
| `shell` | `powershell` / `cmd` / `bash`；脚本先落成临时文件再执行，绕开引号与换行转义 |
| `cline.bin` | **必须绝对路径**：Windows 上 `cline` 通常不在 PATH 里（`%LOCALAPPDATA%\...\cline.cmd`） |
| `cline.planArgs` / `actArgs` | plan 走 `-p`（只读），act 走 `--auto-approve true` |
| `cline.resume` | **已停用（默认 false）**：`--id` 续会话要求 TTY，无头 bridge 用不了；一律 `-c <workspace>` 新开会话 |
| `allowModes` | 模式白名单，`yolo` 默认不在内；被拒命令直接 `failed` 并写明原因。**2026-11-01 起默认只留 `plan`** |
| `workspaceWhitelist` | **同时约束远程执行的工作目录**（空数组 = 不限制）。条目是绝对路径按前缀比，是纯名字按目录名精确比；不命中直接 `failed`。自检：`npm run check:whitelist` |
| `defaultWorkspace` | 命令未带 `workspace`（或路径不存在）时的默认工作目录 |
| `timeoutMs` | 超时强杀进程树（`taskkill /t /f`），回写 `timeout after ...` |
| `batchSize` | 单轮最多取几条，串行执行 |

两个 Windows 细节（都踩过）：`cline.cmd` 是批处理，Node 直接 `spawn` 会 `ENOENT`，必须过一层 `shell`；
`spawn` 的 stdin 必须是 `'ignore'`，否则 cline 一直等终端输入，命令永远停在 `running`。

改完想确认链路通不通，跑 `deploy\windows\verify-hub.ps1`（见 `deploy/README.md` §13）。

### 常驻与开机自启

```powershell
# 起（别用 bash 的 nohup，会把终端 shell 一起带走）
Start-Process -WindowStyle Hidden node -ArgumentList 'src/index.js' `
  -WorkingDirectory 'C:\Users\alice\.cline\data\workspaces\chat\cline-hub\bridge'
```

开机自启用**启动文件夹**里的 VBS（不需要管理员权限）：

```vbscript
' %APPDATA%\Microsoft\Windows\Start Menu\Programs\StartUp\ClineBridge.vbs
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = "C:\Users\alice\.cline\data\workspaces\chat\cline-hub\bridge"
sh.Run "node ""C:\Users\alice\.cline\data\workspaces\chat\cline-hub\bridge\src\index.js""", 0, False
```

> **当前状态（2026-11-01 起）**：本机这个 VBS 已被改名为 `ClineBridge.vbs.disabled`（bridge 不再开机自启）。
> 恢复自启：把文件名改回 `ClineBridge.vbs`；或者只改 `config.json` 里的 `commands.enabled` 手动起一次。
>
> 想换成计划任务得用**管理员** PowerShell：
> `schtasks /create /tn ClineBridge /sc onlogon /rl limited /f /tr "node C:\Users\alice\.cline\data\workspaces\chat\cline-hub\bridge\src\index.js"`
> （普通权限会 `ERROR: Access is denied.`）

## 安全基线（2026-11-01 事故复盘后）

起因：本机 PowerShell 窗口出现「自动输入 + 下载进度」，怀疑被远程控制。逐项排查（过程与证据见
[`docs/bridge-notes.md`](docs/bridge-notes.md) §7）结论是 **没有入侵痕迹**：无远控软件、RDP 已禁用且
3389 无监听、无异常启动项/WMI 订阅、Defender 无威胁、4104 脚本块日志只来自本机会话。
唯一「能从外部下命令」的入口就是本项目自己的 bridge —— 它不是被攻破，而是**默认配置太宽松**。

因此按「默认不接受远程命令」重塑：

| 项 | 现在 | 说明 |
|---|---|---|
| `commands.enabled` | `false` | 命令一直留在 `pending`，不会被执行 |
| `commands.allowModes` | `["plan"]` | `act`/`yolo` 从手机下发一律 `failed`；要开 act 必须**同时**改这里和 `actArgs` |
| `workspaceWhitelist` | 两个绝对路径 | **执行侧也校验**（原来只用于采集），手机传 `workspace=C:\Windows\System32` 会被拒 |
| 开机自启 | 已停用 | 启动文件夹里是 `ClineBridge.vbs.disabled`，恢复方法见下节 |

明文 HTTP 期间（备案没下来之前）的额外要求：

1. 不要长期挂着 bridge；要用时手动起，用完杀（精确杀进程的命令见 §5 `docs/bridge-notes.md`）；
2. `hubUrl` 的随机前缀与 `deviceToken` 视为「可能已泄露」，**切回 HTTPS 当天必须轮换** device/app token；
3. token 只用 `npm run create-device` 现生成，任何截图/日志/工单里都不出现明文；
4. 手机上只发 `plan`，别在明文信道上发 `act`。

本机运维脚本约定：**统一用 `.bat` 做入口**（`.ps1` 的右键菜单没有「以管理员身份运行」，
默认还会被记事本打开）。本次留存的脚本在 `%USERPROFILE%\Desktop\security-check-20261101\`：
`admin-run.bat`（自提权跑 guest/计划任务清理，`/check` 只复核不执行）、`enable-bridge.bat`（恢复自启）。
自提权判断**不要用 `net session`** —— 本机非管理员会话也返回 0，会静默跳过 UAC。

### 备案期内的 HTTPS 入口（2026-11-01 起可用）

`hub.littlewish.top:8443` 已配好**真 HTTPS**，复用 Caddy 已签发的 Let's Encrypt 证书
（`notAfter 2027-01-29`），不改动 80/443 的现有站点：

```
客户端 → https://hub.littlewish.top:8443/api/v1/...  → Caddy(TLS) → 127.0.0.1:3100
```

| 项 | 说明 |
|---|---|
| 原理 | 未备案拦截只作用于 **80/443**（按端口 + SNI）；8443 + 合法 SNI 不走那条规则 |
| 前置 | 腾讯云控制台 → 防火墙/安全组 **放行 TCP 8443**（主机侧不用改：`ufw` 未启用，iptables 只 REJECT 了某个扫描 IP 的 22） |
| 服务器内验证 | `curl --resolve hub.littlewish.top:8443:127.0.0.1 https://hub.littlewish.top:8443/api/v1/health` → **200**（严格校验证书通过） |
| 外网验证 | `curl -sS -o NUL -w '%{http_code}' https://hub.littlewish.top:8443/api/v1/health` → 放行后应为 `200` |
| 回退 | `sudo cp /etc/caddy/Caddyfile.bak-20261101-8443 /etc/caddy/Caddyfile && sudo systemctl reload caddy` |

**放行之后的切换清单**（顺序别乱）：

1. `bridge/config.json` → `hubUrl: "https://hub.littlewish.top:8443"`（**去掉 `/_h/<前缀>`**，前缀只是明文的兜底口令）；
2. App 设置页 → Hub 地址同上；
3. **轮换 device/app token**（旧 token 已经在明文 HTTP 上传输过，视为已泄露）；
4. 确认无误后再考虑用 `enable-bridge.bat` 恢复开机自启。

#### 当前状态（2026-11-01 19:16 实测）

| 项 | 状态 |
|---|---|
| 外网 `https://hub.littlewish.top:8443/api/v1/health` | **200**，证书链严格校验通过（`verify=0`，CN=hub.littlewish.top，到期 2027-01-29） |
| 安全组 | 已放行 TCP 8443 |
| `bridge/config.json` | 已切 `https://hub.littlewish.top:8443`，`commands.enabled=false`、`allowModes=["plan"]` |
| token | device 已轮换（`clh_b194fa8c…`，更早的值全部失效）；app token 未变（`clh_ad58bfa7…`），在 `.secrets/phone-token.txt` |
| bridge 进程 | 手动启动（不自启），日志出现 `command worker disabled`，会话上报走 HTTPS |
| 鉴权验证 | `GET /sessions` 200；`http://82.157.153.22/_h/<前缀>/api/v1/health` → **404**（明文入口已关） |
| App | **待你更新**：Hub 地址换成 `https://hub.littlewish.top:8443`，token 用 `.secrets/phone-token.txt` |
| IP 明文兜底入口 | **已删除**（Caddyfile 整段移除，只保留静态落地页；备份在服务器 `/etc/caddy/Caddyfile.bak-*`） |

> ⚠️ **证书续期是个坑**：Caddy 默认走 HTTP-01（80 被劫持）/ TLS-ALPN（443 被重置），
> 两者都会失败。2027-01-29 之前必须改成 **DNS-01**（带 DNSPod DNS 插件重编译 Caddy），
> 或手动签发后在站点里写死 `tls <crt> <key>`。

备案通过后的正路：删掉 `http://82.157.153.22` 兜底块，客户端直接回 `https://hub.littlewish.top`（443）。

## 约定

- 仓库内**不出现任何真实口令/token**；`bridge/config.json` 与 `.env` 均被 gitignore。
- `.ps1` 文件保持 **ASCII-only**（Windows PowerShell 5.1 会把无 BOM 的 UTF-8 当 ANSI 读，中文会乱码）。
- Hook 脚本**永不阻塞**：任何异常都 `exit 0`，失败只写 `%USERPROFILE%\.cline\notify.log`。

## 许可证

代码以 [MIT](LICENSE) 发布（Copyright © 2026 a9653）：随便用、改、商用、闭源分发，
只需保留版权与许可声明。不提供任何担保。

两点说明：

- **名字与标识不在授权范围内**——基于本仓库改的东西请另起名，别让人误以为是上游版本
  （MIT 本身没有商标条款，这句只是态度）。
- `docs/` 与 `site/` 里的文字同 MIT 发布，但里面的截图/示例若有第三方内容，各自归属原主。
