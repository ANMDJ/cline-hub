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

## 11. 备案没下来前，入口走「IP + 随机前缀」明文 HTTP

`hub.littlewish.top` 未备案，大陆机器上 80/443 会被腾讯云边缘拦：443 握手阶段注入 RST，
80 直接 302 到 `dnspod.qcloud.com/static/webblock.html?d=...`；同一台机的 IP 直连不受影响
（细节与证据见 `deploy/README.md` §11）。

所以临时入口是 `http://82.157.153.22/_h/<openssl rand -hex 16>`：

- 前缀本身就是口令，存在本机 `.secrets/hub-http-prefix.txt`，**不进仓库、不写文档**；
- Caddy 只在该前缀下反代，其余路径 `404`（配合 `uri strip_prefix`，Hub 代码零改动）；
- 复用同一套 token/路由，迁移成本为零；域名与 HTTPS 配置保留，备案通过后删除 IP 站点即可切回。

**代价与补偿**：明文传输意味着 token 可被嗅探。补偿是限流（ADR-12）+ 前缀不可猜 + 备案后立刻轮换 token。
这是「能继续开发 M2b」和「安全」之间刻意选的中间态，不是终态。

## 12. 限流与白名单放在 Hub 自己身上，不依赖 Caddy 插件

Caddy 标准发行版没有 rate_limit 插件（要自己 xcaddy 重编译），而入口可能换（域名 / IP / 以后加 Cloudflare），
所以把防护做进 Hub：`server/src/net.js` 提供

- `clientIp()`：只有直连方是回环（即本机 Caddy）时才信任 `X-Forwarded-For`，否则用 socket 地址；
- 令牌桶（默认 `120` 突发、`5/s` 恢复，`HUB_RATE_LIMIT_*` 可调），超限 `429 + retry-after`；
- 可选 `HUB_ALLOW_IPS`（IP 或 IPv4 CIDR，逗号分隔）。默认留空：手机流量 IP 会变，硬白名单会把自己锁在外面；
  本机回环永远放行，保证 health/smoke 不被误伤。

单实例部署够用；真要多实例时把桶换成 Redis 计数即可，接口不变。

## 13. 落地页用纯静态 + Caddy `file_server`，不引入 nginx

项目要开源，就需要一个「一眼看懂这是什么」的页面。三种选法：

| 方案 | 说明 | 结论 |
|---|---|---|
| GitHub Pages | 零运维，但大陆访问不稳，且项目自托管叙事下显得割裂 | ✗ |
| 引入 nginx 专门跑静态 | 多一个常驻服务、多一套日志/证书/端口要维护 | ✗ |
| 现成的 Caddy 加一个 `file_server` 站点 | 复用已有 TLS、日志、安全头；改文件即生效，无需 reload | ✅ |

页面本身坚持三条：**零构建**（没有 npm/打包器，克隆下来双击就能看）、**零外部资源**
（字体用系统栈、图标手写 SVG，不挂 CDN，也顺手避开大陆 CDN 抽风）、**可自检**
（`node site/check-site.mjs` 检查标签配对、CSS 括号、引用文件、锚点 id，非 0 退出，可进 CI）。

站点根目录 `/var/www/cline-hub` 与 Hub 的 API 前缀 `/_h/<prefix>` 共用同一个 IP 站点：
前缀优先反代到 Hub，其余路径落到 `file_server`，所以「网站」和「API」互不干扰，
也不会因为多开端口扩大攻击面。

## 14. App 用「接口抽象 + ChangeNotifier」，Web 预览降级为轮询

M2b 要交付的是「手机上能看会话、能下发命令」。选型上有三条路：

| 方案 | 说明 | 结论 |
|---|---|---|
| 上 Riverpod / Bloc + 代码生成 | 生态最主流，但要引 3~5 个包 + build_runner | ✗ 对这个体量是负债 |
| 直接 `setState` + 页面内各自 fetch | 依赖最少，但 SSE 重连、分页游标会散在五个页面里 | ✗ |
| `HubApi` 接口 + 单个 `HubStore(ChangeNotifier)` | 依赖只有 `http` / `shared_preferences`，事件与分页集中一处 | ✅ |

配套的三个决定：

1. **`HubApi` 是接口**，`HttpHubApi` 是唯一实现，测试里换 `FakeHubApi`。
   这样「模型解析、分页去重、事件去抖、断线退避」都能脱离网络单测（19 个用例，秒级跑完）。
2. **Web 不假装有 SSE**：`package:http` 的 BrowserClient 会把整个响应体缓冲完再给，
   流式解析拿不到增量帧。与其写一套 `dart:html` 分支，不如让 `events()` 在 Web 下返回
  6 秒一次的 `tick`，由 `HubStore` 按节拍轮询 REST——行为一致，代码少一半。
  Android 仍走真 SSE（`HttpClient` 流式），25 秒 `: ping` 心跳 + 1/2/5/10/20s 退避重连。
3. **明文 HTTP 只在这段时间存在**：Android 侧开了 `usesCleartextTraffic`、并显式声明
  `INTERNET` 权限（release 构建不会自动带）。备案通过切 HTTPS 后，这个开关要删掉，
  token 也要轮换——这一点写进了 App 设置页的「安全提示」，避免以后只有我记得。


## 15. 许可证选 MIT，而不是 Apache-2.0 / AGPL

M2b 收尾时要发布落地页，页脚和根目录都缺许可证，得先定。

| 方案 | 说明 | 结论 |
|---|---|---|
| AGPL-3.0 | 谁改了对外提供服务就得开源 | ✗ 自用项目用不上这种防御，反而挡住别人在公司内网部署 |
| Apache-2.0 | 带专利授权、要求标注修改、维护 NOTICE | ✗ 条款更重，对这个体量收益不明显 |
| MIT | 一段话读完，生态（Caddy / Flutter / 本仓库依赖）大多同族 | ✅ |

配套的三个决定：

1. **只有根目录一份 `LICENSE`**，不在每个子目录复制副本（副本一改就会漂移）；
   `server/` 与 `bridge/` 的 `package.json` 只声明 `"license": "MIT"` 字段。
2. **「别用同名发版」写在 README，不写进 LICENSE**——往 MIT 正文里加限制就不再是 MIT，
   工具和平台（GitHub 许可证识别、公司合规扫描）都会认不出来，损失大于收益。
3. **依赖侧不另外维护清单**：不分发预编译二进制（APK 由使用者自己 `flutter build`），
   `flutter pub deps` / `npm ls` 随时可查，没有额外的 bundle 义务。
