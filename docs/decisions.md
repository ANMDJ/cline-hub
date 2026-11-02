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


## 16. 会话上报：`running` 也上传，靠「指纹」而不是「id 名单」去重

手机上一直看不到「正在跑的那条会话」和最新一句话。根因在 bridge 的上报策略，
不在 App —— App 早就支持 `running → 执行中` 的展示。

| 方案 | 说明 | 结论 |
|---|---|---|
| 只上报终态（原实现） | `running` 只塞进 `pendingRunning`，等结束再发 | ✗ 长会话几十分钟都查不到，最新消息也看不到 |
| 每条消息都推 | Cline 每产生一条消息都会刷 `updated_at` | ✗ 长会话把 outbox 和 Hub 的 upsert 打成每 5 秒一次 |
| 指纹 + 节流（现方案） | `status\|updated_at` 没变就不发；`running` 最多 15 秒一次 | ✅ |

配套的三个修正：

1. **去重从「id 数组」升级成 `{ sessionId: 指纹 }`**：旧实现是
   `if (sentSessions.includes(id)) return`，一个会话只要上报过一次，后续再聊、
   状态从 `failed` 变 `completed` 都不会再推，手机永远停在第一次的快照。
   迁移时旧 id 给空指纹，并打 `needsBackfill`。
2. **一次性回填**：水位线（`lastUpdatedAt`）只向前推进，被旧逻辑静默跳过的会话
   其 `updated_at` 早已落在水位线以下，`listSessionsSince` 再也扫不到。
   升级后按 `updated_at desc limit 100` 取一次最近会话重推，指纹相同的自动跳过，
   `needsBackfill` 落盘为 `false`，不会每次启动都跑。
3. **`userPrompt` 取「最后一条真人输入」**：Cline 会把 `[TASK RESUMPTION] …`、
   `<hook_context …>`、`<environment_details>` 这类注入文本也放进 `user role`，
   原来的 `last user text wins` 会把真实 prompt 顶掉（实测 `userPrompt` 变成了
   `[TASK RESUMPTION] Please continue where you left off.`）。
   现在只认 `<user_input>…</user_input>` 里的正文，其余以 `<` 开头的注入文本跳过，
   全被跳过时退回 `sessions.prompt`。

## 17. 指令执行要「诚实」：非终止错误 + 失败原因回写

实测：手机上发「app 开机加载白屏，会话详情加载卡顿」，Hub 上显示 `done`、`exit 0`，
而 `resultText` 只有一段 `CommandNotFoundException` —— 手机以为跑成功了，实际什么都没干。

两层原因：

1. `commands.template` 默认 `{prompt}` ＝「prompt 就是 PowerShell 脚本」，中文自然语言
   被当成命令名；而 PowerShell 的「找不到命令」只是**非终止错误**，`-File` 仍然返回 0。
2. bridge 只看退出码，`0` 一律判 `done`，`errorText` 为空，失败原因被埋进 `resultText`。

改法（`bridge/src/command-worker.js`）：

- `hardenScript()`：powershell 脚本前置 `$ErrorActionPreference = 'Stop'`
  （脚本自己赋过就不加，后赋值会覆盖前缀），让「命令/路径不存在」变成终止错误 → `exit 1` → 上报 `failed`。
- `failureReason()`：非 0 退出且没有 `child.on('error')` 信息时，从输出里挑第一条匹配
  `error|not recognized|not found|denied|cannot|无法|不是` 的行，写成 `exit code 1: <那行>`，
  App 的红色错误框直接显示根因，而不是干巴巴的 `exit code 1`。

顺带纠正一条旧结论：本机**有** `cline` CLI（`cline@3.0.74`，装在
`%LOCALAPPDATA%\Author Software\nvm\installs\v26.10.0\cline.cmd`），
但**不在 PATH 上**（新开的 PowerShell 里 `Get-Command cline` 解析不到）。
若想把手机指令交给 AI 执行，`template` 必须写绝对路径 + 调用符：

```json
"template": "& \"C:\\Users\\alice\\AppData\\Local\\Author Software\\nvm\\installs\\v26.10.0\\cline.cmd\" --yolo \"{prompt}\""
```

`--yolo` 真的会改文件、跑命令，等价于把手机变成无人监督的执行端，先确认 headless 授权再开。

## 18. 会话详情要「逐条」，完成通知由 bridge 自己兜底

三个现象同一批修：详情页只有一句话、执行中的消息不出现、动态页永远收不到「已完成」。

| 层 | 根因 | 改法 |
|---|---|---|
| 抽取 | `extract.js` 里 `resultText` / `userPrompt` 都是 last-wins，`sessions` 表只有一列 `result_text` | 新增 `extractTranscript()`，把 `messages.json` 拍平成逐条消息 |
| 存储 | 没有消息级表 | `002_messages.sql`：`session_messages`，主键 `(device, session, message_id)` |
| 上报 | bridge 每次只发整条会话 | `state.json` 记 `{v, n, tail}` 水位（抽取版本/条数/末条长度），增量发、每批 40 条 |
| 通知 | Cline 4.1.26 把 hooks 目录改成工作区级 `.clinerules/hooks`，老的外挂 `.ps1` 不再触发 | bridge 自己盯 `status` 跃迁，`running → completed/failed/cancelled` 就补一条 hook 事件 |
| 执行 | 手机指令进不来真会话 | `commands.runner: "cline"`，带 `sessionId` 用 `--id` 续会话，否则 `-c` 新开 |

实测口径（会话 `1793505205932_g0u8h`）：454 条原始记录 → 241 条可读消息
（5 条真人输入 / 60 条正文 / 176 条命令过程），详情页从「1 条」变成完整对话。

五个必须记住的细节：

1. **`after` 不能默认成 0**。`Number(searchParams.get('after') ?? '')` 里空串转数字是 `0`，
   `seq > 0` 会把第一条（用户原话）永久过滤掉。必须先判 `null`/空串再转数字。
2. **重叠重发 6 条**。流式回复的同一条消息内容会一直变长，只按条数追新会漏更新；
   服务端按 `message_id` upsert，重发是安全的。
3. **`spawn` 必须 `stdio: ['ignore', 'pipe', 'pipe']`**。不关 stdin 时 cline 会等终端输入，
   进程永不退出，手机侧就卡在「执行中」（实测挂住 8 分钟以上）。
4. **Windows 上 `cline.cmd` 是批处理**，Node 不能直接 exec，需要 `shell: true` 且自己给参数加引号。
5. **完成通知只在「见过它 running」时发**：首次回填会翻出几十个历史会话，
   不做这个判断，手机开机会被历史通知刷屏。

### Phase 0 两项实验的结论（2026-11-01 实测）

1. **`cline --id` 不是抢锁，是无头环境下根本用不了**：

   ```
   $ cline --id 1791688899478_78ppl -p "reply ..."      # stdin/stdout 都是管道
   error: interactive mode requires a TTY (stdin/stdout must both be terminals)
   ```

   加 `--zen` 一样报错；换成 `cline -c <cwd> -p "..."` 则正常（实测 7.6s、`exit 0`、输出 `got it`）。
   本机既没有 `winpty` 也没有 `node-pty`，`cline connect` 是「接外部 channel」而非续会话。

   → 结论：`commands.cline.resume` 停用（默认 `false`），带 `sessionId` 也一律 `-c` 新开会话。
   App 的「继续对话」语义因此变成「新建一个会话接着说」，UI 已同步注明。
   想要真正的续聊，后续只有两条路：实现 `cline --acp` 客户端（stdio JSON-RPC），或给 bridge 引入 pty —— 都记在这里备查。
2. **Cline 4.1.26 不调外部 `.ps1` hook**：侧证是 Hub 的 `hooks` 表里 #1–#12 全部来自 bridge
   自己生成的 `session_done` / `session_failed`，外挂 hook 一条都没有。现方案（bridge 盯状态跃迁）成立。

## 19. 远程命令默认关闭，工作目录白名单在执行侧也校验（2026-11-01）

**触发**：本机 PowerShell 窗口出现「自动输入 + 下载进度」，被怀疑有人远程控制。逐项排查（证据见
`docs/bridge-notes.md` §7）结论是**没有入侵**：无远控软件、RDP 禁用且 3389 无监听、无异常启动项/WMI 订阅、
Defender 无威胁、4104 脚本块日志只来自本机会话。**能下命令的只有本项目的 bridge。**

问题不在「被攻破」，而在「默认太宽松 + 明文 HTTP」：

| 缺口 | 后果 |
|---|---|
| `workspaceWhitelist` 只在 `index.js` 用于采集过滤 | 手机发 `workspace=C:\Windows\System32` 就能在任意目录执行 |
| `allowModes` 默认含 `act` → `--auto-approve true` | 无人值守跑完整 act 会话，机器前没有人在看 |
| 启动文件夹 VBS 常驻 | 一旦 token 被嗅探，攻击窗口是 7×24 |
| 明文 HTTP（ADR-11 的已知代价） | token 在链路上裸奔 |

**决定**：

1. `commands.enabled` 默认 `false` —— 命令停在 `pending`，要执行必须显式打开；
2. `allowModes` 默认只剩 `plan` —— `act`/`yolo` 直接 `failed`，原因回写给手机；
3. 抽出纯函数 `isWorkspaceAllowed(dir, whitelist)`，**执行侧独立校验**：绝对路径条目按目录前缀比
   （`...\chat` 不放行 `...\chatty`），纯名字条目按目录名精确比（与采集侧同义）；越权或 `..` 跳出 → `failed`；
4. 自检脚本 `bridge/scripts/check-workspace-whitelist.mjs`（`npm run check:whitelist`，10 条用例、零依赖），
   跟 `site/check-site.mjs` 一个路子：非 0 退出码可直接进 CI；
5. 本机开机自启的 `ClineBridge.vbs` 改为 `.disabled`，等切回 HTTPS + 轮换 token 后再恢复。

**不做的事**：不给 `actArgs` 塞 `--auto-approve false` 这种没实测过的取值 —— 把 `act` 从 `allowModes`
拿掉更彻底，也不用去猜 CLI 对布尔参数怎么解析（§18 的 Phase 0 实验已经教过一次：别猜，先实测）。

## 20. 备案期内用 `:8443` + 现有 LE 证书提供 HTTPS（2026-11-01）

**问题**：明文 HTTP 入口（ADR-11）让 token 在链路上裸奔；但 80/443 被未备案拦截
（80 被 302 到拦截页、443 的 TLS 握手按 SNI 重置）。想上 HTTPS，却被「等备案」卡住。

**实测调查**：

| 事实 | 证据 |
|---|---|
| 证书其实**早就签下来了** | `/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/hub.littlewish.top/`，`notAfter=2027-01-29`，证书本身没问题 |
| 服务器只监听 80/443 | `ss -ltn`：`*:80`、`*:443`（Caddy v2.11.7） |
| 主机防火墙不是卡点 | `ufw` inactive；iptables 只有一条对 `193.32.162.167` 的 22 端口 REJECT |
| 卡点是**云安全组** | 外网 `80/443` TCP 可连，`8443` TCP 超时 → 只有安全组没放行 |

**决定**：新增一个 `hub.littlewish.top:8443` 站点，复用同一张证书和同一套反代配置
（SSE 的 `flush_interval -1`、`read_timeout 0` 照抄 443 站点），**不动**现有 80/443 的站点。
纯加法：`caddy validate` 通过 → `systemctl reload caddy` → 想回退只需 `cp` 回
`/etc/caddy/Caddyfile.bak-20261101-8443`。

**验证**：服务器内 `curl --resolve hub.littlewish.top:8443:127.0.0.1`（**严格校验证书**）返回 `200`；
安全组放行 TCP 8443 后，外网 `curl https://hub.littlewish.top:8443/api/v1/health` 也返回 `200`，
证书链严格校验通过（`verify=0`）。随后 device/app token 全部轮换，bridge 切到 HTTPS 并重启，
`GET /sessions`、`GET /commands/pending` 均 200；`commands.enabled=false` 时日志打印
`command worker disabled`——即「能上报、不能远程执行」。

**已知代价 / 退路**：

1. 证书续期不能再用 HTTP-01 / TLS-ALPN，得改 **DNS-01**（DNSPod 插件，需重编译 Caddy）或手动写死 `tls <crt> <key>`；
2. 非标端口对个别企业网络不友好（一般无碍）；
3. 若腾讯云连非标端口的 TLS 也拦：退路是 **Cloudflare Tunnel**（零开放端口、无需备案、公网 HTTPS 由 CF 提供）
   或**自签 CA + 客户端指纹固定**（bridge 用 `NODE_EXTRA_CA_CERTS`，Flutter 用 `SecurityContext`）。

`deploy/Caddyfile` 已同步这段配置，避免以后 `cp deploy/Caddyfile /etc/caddy/Caddyfile` 把它覆盖掉。





## 21. cline CLI 无头执行的四个坑（2026-11-01 全部实测）

1. **`--id` 需要 TTY**（详见 ADR-18）：无头 bridge 一律 `-c` 新开会话。
2. **不要用 `shell: true` 跑 `.cmd`**：cmd 会重解析整行，`...\Author Software\...` 里的空格把命令截断成
   `'C:\Users\alice\AppData\Local\Author' is not recognized`（cmd_d780a52e6c1a 实测）。
   改为 `node <node_modules/cline/bin/cline> ...`（`resolveClineTarget()` 自动推导），无 shell、无引号地狱，
   顺带还能保持 `stdio: ignore`（否则 cline 会等终端输入而挂住）。
3. **停掉陈旧的 cline hub daemon**：它连续跑满 4h39m 后，CLI 每次都在收尾阶段报
   `hook dispatch failed: session.hook requires a valid hook event payload` 并 `exit 1` —— 其实活已经干完了。
   排查特征：同一条命令早先成功、之后必失败，且清空 hooks 目录 / 停 bridge / 换 cwd 都无效。
   `cline doctor` 会显示 `hub healthy yes (pid=...)`；杀掉那个 pid，CLI 会自动拉起新 daemon，立刻恢复。
4. **白名单比较必须统一斜杠**：cline CLI 写库用 `C:/...`，人手填的白名单是 `C:\...`，直接 `includes`
   会把 CLI 产生的会话全部误杀（实测 1793531135718_fl56b 被过滤）。`normalizePath()` 先
   `replace(/\\/g, '/')` 再比。

两条运维细节：

- PowerShell 5.1 的 `Set-Content -Encoding UTF8` 会写 **BOM**，`JSON.parse` 直接抛错、bridge 起不来；
  改 JSON 必须用 `[IO.File]::WriteAllText(path, text, [Text.UTF8Encoding]::new($false))`。
- 本机某些会话里 `netstat` 看不到 `127.0.0.1:3210`（`Get-NetTCPConnection` 也不报），用它判断 bridge
  是否存活会误判；改用 `Invoke-WebRequest http://127.0.0.1:3210/health`（`verify-hub.ps1` 已改）。

## 22. 用「项目根」而不是「启动目录」识别工作区（2026-11-01）

**问题**：会话的 `workspace` 来自 cline 记录的 `workspace_root`，也就是「终端在哪个目录启动的」。
在 `C:\Users\alice` 里开的会话就叫 `alice`，在 `...\chat` 里开就叫 `chat` —— 分组是一堆目录名，
跟「我在做哪个项目」完全对不上。

**做法**：bridge 的 `src/project.js` 里 `projectInfo(dir)` 向上最多 8 层找项目根：

1. **第一轮只看 `.git`**。必须整条链扫完 `.git` 再扫标记文件 —— 否则 `...\cline-hub\bridge`
   会先命中自己的 `package.json`，被判成 `bridge` 项目（实测就是这样错的）。
2. 第二轮才认 `pubspec.yaml` / `package.json` / `go.mod` / `Cargo.toml` / `pyproject.toml` /
   `gradlew` / `pom.xml` / `*.sln` / `*.csproj`。
3. 都没有：在家目录（含子目录）之下 → `projectKind=loose`（散会话）；其余用目录名。
4. 结果按小写路径缓存，同一目录不重复 stat。

判定随会话上报（`project` / `projectRoot` / `projectKind`），Hub 存在 `003_projects.sql` 新增的三列，
App 按 `projectRoot` 分组。实测：`C:\Users\alice` → loose；`...\chat\cline-hub` 与
`...\chat\cline-hub\bridge` → 都是 `cline-hub`。

**代价**：

- 迁移前入库的旧会话 `project` 为 `null`，App 回退到按绝对路径分组；
- 改识别规则后要重算历史，得清空 `state.json` 的 `sentSessions`（指纹没变不会重推），
  实测重扫 67 条、耗时 1s 量级。`notifyCompletion` 依赖 `previous` 是 running 才发通知，
  所以清空不会刷一屏通知。

## 23. 会话列表扁平化，「按项目翻」下沉到二级页（2026-11-01）

**问题**：列表按工作区分组 + 组内折叠，最新会话会被压在某个组里；开 App 十有八九是想看
「最近发生了什么」。

**做法**：

- 主列表改**扁平**，顺序完全由服务端 `sortAt`（`coalesce(ended_at, updated_at, started_at)`）决定，
  客户端不重排 —— 最上面永远是最新对话；
- 分组能力保留在 `WorkspacesPage`（主列表顶部「按工作区浏览」进入），组头可折叠，
  散会话（`loose`）永远排最后；
- 卡片抽成 `SessionTile` 给两个页面共用，避免样式漂移。

**分页**：首屏 60 条，滚到底用 `before=<cursor>` 上拉翻历史；`running` 会话有新消息时
自动贴底，不打断正在翻旧消息。

## 24. 无头跑 cline 必须显式 `-P/-m`（2026-11-01 事故复盘）

**现象**：App 下发的 3 条 act 命令全部 `failed`（`exit 1`），输出：

```
error: hook dispatch failed: session.hook requires a valid hook event payload
error: Free model promotion ended
```

**根因**：`runCline()` 只拼了 `[planArgs|actArgs, ...extraArgs, -c cwd, prompt]`，**没传 `-P/-m`**。
CLI 于是按 `~/.cline/data/settings/providers.json` 的 `lastUsedProvider`（当时是 `cline` →
`cline-free/deepseek-v4.1-flash`）跑；那个免费模型下线后，每次无头运行都 exit 1。
`hook dispatch failed` 只是同一轮失败的噪音，不是根因。

**修复**：新增 `commands.cline.provider` / `commands.cline.model`，渲染成 `-P`/`-m`，
位置在模式参数之后、`extraArgs` 之前：

```js
const args = [...(mode === 'plan' ? planArgs : actArgs)]
if (clineOpts.provider) args.push('-P', clineOpts.provider)
if (clineOpts.model) args.push('-m', clineOpts.model)
args.push(...clineOpts.extraArgs, '-c', cwd, prompt)
```

验证：`cmd_1a45c01cc11a`（act）→ `done`，`resultText` 是 `[thinking] … ACT-OK`，
`cline.log` 里该会话 `providerId=deepseek`、`modelId=deepseek-flash`。

**顺带踩到的三个坑**：

1. **`-m` 会落盘**：临时跑一次 `cline … -m cline-free/mimo-v2.6-flash`，CLI 把
   `providers.cline.settings.model` 改成了 mimo（`providers.json` 的 `updatedAt` 同步刷新）。
   所以做验证必须 `--config <临时目录> --data-dir <临时目录>`，别碰用户主配置。
2. **在会话里跑 `cline` 会接入活会话**：子进程继承环境变量，命令行里带上 `--id <当前会话>`；
   它失败时会把正在用的会话标成 `session_failed`（实测 23:09:53 触发，终端直接断连重连）。
   要么用隔离 data 目录，要么先清掉 `CLINE_*` 环境变量。
3. **ID 打错会污染终端**：`cline --id 1793544082344_zpis`（少一个 `z`）→ `SessionNotFoundError`
   → `unhandledRejection` 直接甩进终端；TUI 被中断时没关鼠标追踪，之后鼠标一动就往输入行吐
   `[555;39;1M` 这类 `CSI M` 转义码。清理：`Ctrl+C` 然后 `cls`，不行就关标签重开。

**当前取值**（`bridge/config.json`）：`provider=deepseek`、`model=deepseek-flash`、
`allowModes=["plan","act"]`、`commands.enabled=true`。

## 25. 命令要回写它创建出来的会话 ID（2026-11-01）

`commands.session_id` 以前只有「App 指定续会话」时才填；bridge 一律 `-c` 新开会话，
于是它永远是 `null`，手机上发完命令看不到这条命令落到了哪条会话。

**做法**：

1. bridge 运行前快照 `~/.cline/data/sessions/` 的目录名；
2. 运行中每 1.5s 扫新增项，用会话 JSON 里的 `cwd` / `workspace_root` 跟本次工作目录比对
   （并发跑多条命令时靠它区分，只有一个新增就直接用）；
3. 拿到 ID 立刻 `PATCH status=running&sessionId=...` 回写，命令结束前再查一次兜底；
4. 服务端 PATCH 接受 `sessionId`，SQL 写成 `coalesce($5, session_id)` —— 只写一次，
   后续上报不会把它清空；
5. App 命令详情新增「打开会话」，点一下直接推 `SessionDetailPage`。

实测：`cmd_a0ad0afa4574`（act）执行后 `sessionId=1793548380890_qij68`，
`GET /sessions/1793548380890_qij68` 可查到，`project=cline-hub`。

## 26. 「动态」里正在跑的会话显示执行失败：状态抖动 + 僵尸会话（2026-11-01）

**现象**：手机上「动态」被同一条 `session_failed` 刷屏（kids_points_app 的
`1793406873889_kz6g7`，20 分钟 91 条），而那条会话看上去还在跑。

**根因（两层）**：

1. **状态抖动**：cline 会把这条会话周期性写成 `failed` 再翻回 `running`，每次还带一个
   新的 `ended_at`。原来的去重键是 `status + ended_at`，每次都不一样 → 拦不住。
2. **僵尸会话**：DB 里 `status=running`，但 `pid`（6892）早就没了 —— 这是昨天 VS Code
   那个会话的残留，既被当「执行中」上架，又会在两态之间来回翻。

**修法**（全部在 bridge，`src/index.js` + `src/db.js`）：

- `sessionState(row)` 统一归一化：
  - `status=running` 但 pid 已死 → 判 `failed` 并打 `zombie` 标记；
  - `status=failed` 但没有 `ended_at` → 判 `running`（没结束时间就没结束）；
  - `status=failed` 且 pid 已死 → 也打 `zombie`（可能是真失败，也可能是抖动，交给下面两层去压）。
- **完成通知先排队再确认**：`scheduleCompletion` 只入队，`flushCompletions` 在 30 秒后复查，
  仍是同一个终态才发；中途翻回 running / 换了终态就丢弃。幂等键对僵尸固定成 `failed|zombie`。
- **快照节流分两档**：live 5 秒一次（原逻辑），僵尸 10 分钟一次 —— 否则每一轮 poll 都会因为
  `updated_at` 变化而重发一次快照。
- `db.js` 的 `SESSION_COLUMNS` 补上 `pid`（判断进程存活要用）。

**实测**：改完后 1 分半内该会话只有 1 次快照、0 条完成通知；Hub 上它的状态稳定为 `failed`
（符合事实：进程已死），正在用的 `1793544082344_zpisz` 仍是 `running`。

**历史数据**：误发的 98 条 `session_failed` 已从 Hub 的 `hooks` 表删除，删除前备份在
`%TEMP%\hooks-kz6g7-backup.csv` 与 `hooks-kz6g7-backup2.csv`（仍在另一台机器上就不可见了，
需要的话从 VPS 的 `/tmp` 或日志里再取）。

## 27. cline CLI 把「不含空白的单个词」当子命令（2026-11-01）

**现象**：App 下发 `java`、`安装包可以传给我吗` 都立刻 `failed`，错误是
`Unknown command or unquoted prompt: <prompt>`；同一套配置发
`只回复一行 ACT-OK，不要运行任何命令。`（带空格）却正常。

**根因**（从 `@cline/cli-windows-x64/bin/cline.exe` 里读到的实现）：

```js
function Ge(e){ return !!e && /\s/.test(e) }   // 含空白才像 prompt
function Ye(e){ z(`Unknown command or unquoted prompt: ${e.join(" ")} …`) }
```

单个位置参数**没有任何空白**时，CLI 会把它当成子命令名（`auth` / `doctor` 那一类），
认不出来就报上面那句。中文用户一句话经常不打空格，所以这个坑命中率很高。
跟 provider、token、workspace 全都无关。

**修法**（`bridge/src/command-worker.js` 的 `runCline`）：

```js
args.push(/\s/.test(prompt) ? prompt : `${prompt} `)
```

只在「完全不含空白」时才补一个尾随空格，其余原样；模型收到的文本多一个空格，语义无影响。
备选是 `args.push(prompt, '')`（靠 CLI 自己 `join(' ')` 补），但那是依赖内部行为，不做。

**实测**：`cmd_d443917048ea`，prompt = `只回复SPACE-OK`（无空格）→ `done`，
`resultText` 含 `SPACE-OK`，`sessionId=1793568956535_um63t` 且已回写。

## 28. 手机发 ACT，CLI 实际按 PLAN 执行（2026-11-02）

**现象**：App 里选 ACT 下发，bridge 日志 `mode:"act"`、会话元数据 `metadata.mode:"act"`，
但会话首条消息被包成 `<user_input mode="plan">`，模型于是只出方案、不改文件。

**证据链**（本机 2026-11-02）：

| 环节 | 实测 |
|---|---|
| bridge 参数 | `actArgs = ["--auto-approve","true"]`（不带 `-p`） |
| CLI 选项表 | `modeExplicitlySet: !!(t.plan \|\| t.act \|\| t.yolo \|\| t.zen)`，但二进制里 **`"--act"` 命中 0 次** |
| CLI 模式解析 | `me(e,r){ if(e.modeExplicitlySet) return e.mode; return r.planActMode ?? e.mode }` |
| 包装函数 | `q_(n,o="act")` → `<user_input mode="${o}">` |

**根因**：CLI **没有 `--act`**，`--auto-approve` 只管审批不改模式；不传 `-p/--yolo` 时，
模式取 `~/.cline/data/settings/global-settings.json` 的 `planActMode`（上一次 UI 停留的模式）。

**修法**：bridge 每次运行生成 `<tmp>/cline-settings-<mode>.json`（`planActMode` = 命令模式），
注入 `CLINE_GLOBAL_SETTINGS_PATH`；`CLINE_PROVIDER_SETTINGS_PATH` 只读指向真实 `providers.json`
（不复制密钥）。跑完读 `<id>.json` 的 `metadata.mode` 核对，不一致就在 `resultText` 末尾追加警告。

**验证**：探针 `1793586094677_7y65n` → `metadata.mode=act`，首条消息 `<user_input mode="act">`；
带工具的探针 `run_commands` 在无审批下执行成功（输出 `PROBE-TOOL-OK`）。

**回退**：`commands.cline.forceModeEnv=false`，行为回到「随 UI 的 planActMode 走」。

## 29. 会话消息在源头被截断，不是 UI 折叠问题（2026-11-02）

**现象**：手机上会话内容「展示不全」，长回复到某处戛然而止。

**根因**：`bridge/src/extract.js` 的 `clip()`：`maxTextChars` 默认 2000 字/条，
`maxResultChars` 默认 4000；服务端 `optionalString(..., 8000)` 还会再切一刀。

**决策**：提升到 `maxTextChars=20000`、`maxResultChars=12000`、服务端上限 40000；
`clip()` 返回 `{text, truncated}`，消息带 `truncated` 标记并入库（migration 004）。

**历史数据怎么补**（这是最容易误解的一步）：`TRANSCRIPT_VERSION` 1 → 2 只是让
`transcriptCursor()` 认为旧水位无效；但 `syncTranscript()` 只会被「有新活动 / running /
回填队列」的会话触发，**静止老会话不会自动重发**。所以额外在 tick 里检测
`entry.v !== TRANSCRIPT_VERSION` 并重开回填队列（最近 60 个，2 个/tick）。

**体量实测**（14,755 条消息 / 80 个会话）：2000 字上限 6.68MB → 20000 字上限 **7.51MB**，
只多 0.83MB；切批改成「40 条 或 64KB」避免撞 Hub 4MB body 上限。

**代价与边界**：一次性重传约 7.5MB；更早的 29 个会话不动；`truncated=true` 时 UI 明确写「原文更长」。

## 30. 「选择题」必须能在手机上回答（2026-11-02）

**现象**：Cline 调 `ask_question` 时，手机上看不到问题与选项，会话就卡在等输入。

**决策**：
- bridge 把 `ask_question` 的 `tool_use` 抽成 `kind=question`，把 `options` 原样带上；
- 服务端单独存 `options jsonb`（migration 005），不塞进 `text` 让客户端用正则猜；
- App 渲染成按钮；点击后的语义是**带上下文新开一条命令**（`关于问题「…」，我选择：X`），
  因为无头 CLI 的会话是一次性的（`stdio: ignore`），bridge 无法中途注入回答。
- UI 在气泡底部写清这一点，避免用户以为能「接着原会话答」。

## 31. App 自更新：清单走 Hub、APK 走静态（2026-11-02）

**约束**：仓库没有 remote（不推 GitHub），所以不能用 GitHub Releases；本机也缺
Android SDK + JDK 17，打不出 APK。

**决策**：
- 发布清单 `latest.json`（version/build/notes/apkUrl/sha256）放服务器 `releases/latest.json`，
  由 `GET /api/v1/app/latest` 读出（`HUB_APP_RELEASE_FILE` 可覆盖）；没发布时 404。
- APK 由 Caddy `file_server` 从 `/var/www/cline-hub/app/` 直出，不经过 Hub 进程（大文件不进 Node）。
- 客户端版本号手工维护在 `app/lib/src/data/app_version.dart`，`release-apk.mjs` 会校验它与
  `pubspec.yaml` 一致后才打包 —— 拒绝「包是 1.1.0、界面显示 1.0.0」。
- 更新 UI 只做「检查 + 展示 + 复制下载地址」：安装必须由系统安装器完成，
  不引第三方安装插件（维持 http / shared_preferences 两个依赖）。

## 32. 列表预览在服务端洗成纯文本（2026-11-02）

**现象**：手机上会话列表的预览行是 `## 对，「有私钥」—— 而且就是 kids.pem`、
命令卡片是 `[2mThe[0m[2m user[0m` 这种，读起来就是「乱码」。
实测最近 12 个会话里 9 个带 Markdown（标题/代码围栏/粗体/表格）；
20 条命令里 13 条带 ANSI（单条 2 万字里有 3500+ 个 SGR）。

**决策**：
- **会话预览在服务端洗**（`server/src/text.js` 的 `plainPreview`）：剥 ANSI → 剥 Markdown
  记号 → 折叠空白 → 按码点截 400 字。原因是客户端只拿到 400 字，若这 400 字全是
  代码围栏和 `##`，客户端再洗也洗不出正文，必须先取 `result_text` 前 2000 字再洗。
  预览是派生数据，App / Web / 以后的通知共用同一份实现。
- `result_text` 原文照旧入库，搜索（`q`）仍走原文 `ilike`；只有 `resultPreview` 变。
- **命令输出不在服务端洗**：`commands.result_text` 是终端回放，App 的 `stripAnsi()`
  只在展示与复制时过滤，库里保留原始字节（P8 做富渲染时可能要用颜色）。
- 截断按**码点**（`Array.from`）：直接 `slice()` 会把 emoji 代理对劈成半个字符。

**代价与边界**：列表查询每行多取 1600 字原文（50 行约 80KB 库内传输，出网仍是 400 字）；
「纯文本化」是去记号不是渲染——表格会变成空格分隔的一行；改规则不需要回填，读时现算。

## 33. 命令进程身份：pid + 启动时间，登记在本机（2026-11-02）

**问题**：手机下发命令后，App 只知道「执行中」，不知道 Windows 上对应哪个进程；
出事时只能按 `node.exe` / prompt 猜，或者按进程名杀（会误伤别的 node / cline）。
P7 的并发池一旦放开，单槽位 `state.child` 只能杀掉最后一条，其余立刻变孤儿。

**决策**：
- `commands` 存 `pid` + `pid_started_at`（migration 006），bridge spawn 成功立刻 PATCH 上报，
  `runner` 一并记录；用 `coalesce` 写入，后续 `done/failed` 不会把身份清掉。
- **pid 与启动时间必须成对**。Windows 会复用 PID，只凭 pid 杀进程可能打到无关进程；
  任何 kill 前都要拿 `Get-CimInstance Win32_Process` 的 `CreationDate` 比一次（容差 5s）。
- 真正决定「能不能杀」的是本机登记文件 `%TEMP%\cline-hub-cmd\running\<commandId>.json`
  （`bridge/src/command-registry.js`）。Hub 上的 pid 只用于展示与复制排查命令，
  **不作为杀进程依据**：Hub 不知道 bridge 何时重启、PID 何时被复用。
- `npm run ps` 是唯一推荐的排查入口：`commandId → pid → 存活/双校验 → 精确 kill 命令`；
  `--kill` 校验失败直接拒绝，`--clean` 收掉已退出 / 被复用的登记。
- bridge 内的子进程集合从单槽位改成 `Map<commandId, child>`，`stop()` 杀掉全部；
  进程结束即删登记，`ps` 只显示还活着的命令。

**代价与边界**：
- `pidStartedAt` 取 spawn 返回后的本地时间，与 Windows CreationDate 有毫秒级误差，故留 5 秒容差；
  超出容差宁可拒绝 kill，也不猜。
- 登记文件落在 `%TEMP%`，机器重启或清理临时目录会丢；这时 Hub 上的 pid 只作历史线索。
- 还不能从手机取消命令（P14 计划 `POST /api/v1/commands/:id/cancel`）；
  当前停止方式是本机 `npm run ps -- --kill` 或等超时。

## 34. 命令孤儿回收：对账放在 bridge，只改状态不杀进程（2026-11-02）

**现象**：`cmd_3ced4a851f4c`（03:40 下发）在手机上永远显示「执行中」，而它开出来的会话
`1793590853159_ewhd0` 已经 `failed`。时间线：03:40:51 bridge 认领并 spawn cline →
03:47:13 bridge 为了加载 P11/P12 被重启，子进程跟着没了 → 会话扫描器把会话翻成 failed，
但 **commands 表只有 bridge 会写**，没人收尾。

**决策**：
- 对账放在 bridge（`command-worker.reconcile()`），因为它才是「本机有没有这个进程」的权威：
  每 60 秒 + 启动时各跑一次，取 `GET /api/v1/commands?deviceId=…&status=running`，
  逐条判断后把没有进程接管的回写成 `failed`，`errorText` 明确写「原来的执行进程不在了，可重新下发」。
- 判定用纯函数 `classifyRunningCommand()`：`owned`（本进程在跑）/ `recent`（进入 running 不足 2 分钟，
  留观）/ `alive`（进程在且 pid+启动时间对得上）/ `orphaned` 才回写。
  证据优先用本机登记，登记被 `%TEMP%` 清掉时退回 Hub 的 `pid` + `pidStartedAt`。
- **不杀进程**：对账只负责「状态别骗人」。真要停某条命令，仍然走 `npm run ps -- --kill <id>`
  的 pid+启动时间双校验（ADR-33）；bridge 重启留下的孤儿由人决定。
- 顺手清掉登记目录里进程已不在 / pid 被复用的文件，`npm run ps` 不再显示假条目。
- 排障入口：`cd bridge; npm run reconcile -- --dry-run` 先看会改哪些，去掉 `--dry-run` 立即回写。

**代价与边界**：
- bridge 完全没起来时没人对账（手机仍会看到 running）；这是「执行者不可用」的必然结果，
  等 bridge 回来会在启动对账里收尾。
- 2 分钟留观意味着刚领取的命令最多多显示 2 分钟；换来的是不会把「正在 spawn」误判成失败。
- 对账只处理最近 50 条 running（`limit`），足够单人使用；真到并发池（P7）再调。

## 35. 手机通知走原生 MethodChannel，不引第三个依赖（2026-11-02）

**需求**：命令完成 / 失败、会话结束时，手机上要有系统通知；不能只靠 App 内 snackbar。

**决策**：
- 原生 `MainActivity` 注册 `top.littlewish.cline_console/notify`，只做三件事：
  `ensurePermission()`（Android 13+ 的 `POST_NOTIFICATIONS`）、`show(id,title,body)`、`cancelAll()`。
  通知通道 `cline_hub_events`（IMPORTANCE_HIGH），小图标是纯白剪影 `ic_stat_hub`。
- Dart 侧 `data/notifier.dart`：`HubNotifier` 接口 + `LocalHubNotifier`（Android）/ `NoopHubNotifier`（Web、测试）。
  `HubStore` 注入接口，测试里换成记录器，不需要 mock 平台通道。
- **不引 flutter_local_notifications**：客户端从第一天起只保留 http / shared_preferences（ADR-31），
  而这里只需要「建通道 + 发通知 + 要权限」；引插件会连带要求 core library desugaring，
  给本来就靠手工配 `JAVA_HOME` 的发版流程再加一个失败点。
- 触发点只有两处：命令 `active → done/failed/cancelled` 的跃迁（首次加载的历史命令不弹）、
  bridge 合成的 `session_done/session_failed/session_cancelled`（不认 `agent_*`，避免和 ntfy 重复）。
  同一个 `commandId:status` / `hook:<id>` 只弹一次（SSE 重放、回前台补拉都会去重）。

**边界**：
- App 退到后台会主动断 SSE 省电（ADR-14 的取舍），这期间**收不到事件**，可靠通道仍然是 ntfy；
  回前台会补拉一次，并把「后台期间结束的命令」补一条通知（`_refreshAfterResume`）。
- 通知点击只打开 App，不做深链到具体命令（需要额外保存 payload → 路由，P8 之后再说）。
- 通知权限被拒时静默失败，设置页「通知」卡片可以再次请求并显示结果。


## 36. 停 bridge 之前先停任务：`/admin/stop` + 优雅 shutdown，再杀进程树（2026-11-02）

**问题**：Windows 上 `Stop-Process` / `taskkill /pid` 是 `TerminateProcess`，Node 收不到
`SIGTERM`，`index.js` 里的 `shutdown()` 根本不会执行。旧实现即使执行了，也是
「先 `killTree()` → 立刻 `process.exit(0)`」，回写 `failed` 的 PATCH 排在后面，来不及发出去。
结果就是：命令的 cline 子进程没了，但 Hub 上的 `commands.status` 一直是 `running`，
手机上的卡片停在「执行中」，要等下一次启动对账或人工 `npm run reconcile` 才收尾
（`cmd_3ced4a851f4c` 卡了 19 分钟）。

**决策**：
- 本机 hook server 增加 `POST /admin/stop`（只认 `127.0.0.1` / `::1`，其他一律 403），
  请求体 `{ "reason": "..." }`。收到后先回 202，再触发 `shutdown(reason)`。
- `commandWorker.shutdown({ reason })` 的顺序固定为：
  1. `state.stopped = true`（不再领取新命令）；
  2. 对 `state.children` 里每条 in-flight 命令并发 `PATCH failed`，`errorText` 用
     `interruptionErrorText(reason)`（写清「bridge 正在关闭（原因），执行进程已停止，
     可以直接重新下发」），每条 3 秒超时；
  3. 杀进程树（`taskkill /t /f`）；
  4. 交给 `index.js` 关 server、存 state、退出。
- `handle()` 在收尾时检查 `state.interrupted`：已经由 shutdown 回写过的命令不再报一次，
  否则「bridge 关闭」会被覆盖成 `exit code -1`。
- 命令行入口：`npm run stop -- --reason "..."`、`npm run restart -- --reason "..."`。
  `restart` 用 `spawn(process.execPath, ['src/index.js'], { detached: true, stdio: 'ignore' })`
  拉起，等价于 `Start-Process`（不用 Git Bash 的 `nohup`，那会把终端 shell 一起带走）。
- **每次主动中断都写 `docs/interruptions.md`**：为什么杀 / 怎么杀 / 影响了谁 / 怎么恢复。
  下次会话读这一页就知道上次为什么断在半路。

**代价与边界**：
- 回写失败（Hub 不可达）不阻塞退出：命令状态留给下次启动的 `reconcile()` 兜底，
  原因会变成「原来的执行进程不在了」而不是「bridge 正在关闭」。
- in-flight 命令被主动中断 = 用户要接受「这次执行作废」。这是「要重启」的必然代价，
  换来的是状态不再骗人；想跑完就先等它结束。
- 硬杀仍然可能发生（蓝屏 / 任务管理器）。所以 `reconcile()` 不能删，两条路径并存。

## 37. App 用系统浏览器直接打开下载地址，不引 url_launcher（2026-11-02）

**问题**：设置页「检查更新」发现有新版本时只提供了「复制下载地址」，手机上要
「复制 → 切浏览器 → 粘贴 → 下载」，多三步，而且粘贴还可能失败。

**决策**：
- `MainActivity` 增加第二个 MethodChannel `top.littlewish.cline_console/links`，
  方法 `openUrl`：只接受 `http` / `https`，用 `Intent(ACTION_VIEW, uri)` 交给系统浏览器。
- Dart 侧 `data/link_launcher.dart`：`LinkLauncher.isHttpUrl()`（纯函数）+ `open()`；
  Web / 非 Android 返回 `false`，UI 自动退回复制并提示「这个环境打不开浏览器，已复制下载地址」。
- 「复制链接」保留：没有浏览器、地址是内网 IP、或者用户就是要粘到别处时仍然用得上。
- **不引 url_launcher**：客户端只保留 http / shared_preferences 两个依赖（ADR-31），
  这个需求在 Android 侧就是一次 `startActivity`；也不需要 `<queries>`（只 launch 隐式
  intent，不做 `resolveActivity` 查询）。`ActivityNotFoundException` → 返回 `false`。

**边界**：
- Web 预览没有原生侧，点了只会复制；这是预览环境的限制，不是功能缺失。
- 打开的是浏览器，下载/安装仍由系统安装器负责（同一签名覆盖安装）。

## 38. 用 `cline --json` 取干净终稿，会话 ID 仍靠目录扫描（2026-11-02）

**问题**：bridge 以前把 cline 的 stdout/stderr 原样回写，手机上看到的是 `[thinking]`、
ANSI 和进度行；失败时只能拿「stderr 里第一条像错误的行」猜原因（`failureReason()`），
遇到认证失败、模型下线这类只有一行 JSON 的错误就猜不准；并发（P7）时也没法从输出里
区分「哪条命令对应哪次运行」。

**实测 CLI 3.0.74 的 `--json` 输出**（9 行样本，隔离 data-dir 跑出来的）：

```json
{"ts":"…","type":"hook_event","hookEventName":"agent_start","agentId":"agent_…","taskId":"conv_…"}
{"ts":"…","type":"agent_event","event":{"type":"iteration_start","iteration":1}}
{"ts":"…","type":"agent_event","event":{"type":"usage","inputTokens":9000,"outputTokens":2,"totalCost":0.0013}}
{"ts":"…","type":"agent_event","event":{"type":"done","reason":"completed","text":"OK","usage":{…}}}
{"ts":"…","type":"run_result","finishReason":"completed","text":"OK","durationMs":1568,"model":{"id":"deepseek-flash","provider":"deepseek"}}
{"ts":"…","type":"error","message":"Authentication Fails (governor)"}   ← 失败时可能只在 stderr
```

**决策**：

- `commands.cline.json` **默认开**，`runCline()` 直接把 `--json` 加到参数里；
  设成 `false` 退回原来的纯文本输出（老版本 CLI 的逃生口）。
- 新增 `bridge/src/cline-json.js`：**增量** NDJSON 解析（chunk 可能在任意字节截断），
  只保留终稿、`finishReason`、`errorMessage/errorClass`、`usage`、`taskId`、工具调用数；
  不把整条事件流堆内存。
- `resultText` 优先用 `run_result.text`（没有则 `agent_event.done.text`），
  **只有 CLI 完全没吐 JSON 时才退回原始 stdout**；失败时 `errorText` 优先用事件里的
  `error.message`，没有才走原来的 `failureReason()`。
- `ok` 不再只看 exit code：`isClineJsonFailure()` 在 `finishReason` 属于
  `error/failed/aborted/cancelled`，或「有 error 且没有终稿」时判失败。
  认证失败实测走的就是这条（CLI 的退出码不可靠）。
- `command finished` 日志补 `finishReason / taskId / toolCalls / outputTokens / cost`，
  手机上仍只看结果与错误，不塞用量。

**边界（重要）**：

- `taskId` 是 `conv_…`，**不是**会话 ID（`~/.cline/data/sessions/<id>`）。实测两者的时间戳
  都不同，`sessions.db.conversation_id` 也是 `null`。所以命令 → 会话的配对**仍然**
  靠「运行前快照 + 扫描新增会话目录 + cwd 比对」（ADR-25），P7 的同 workspace 串行
  也需要它，别拿 `taskId` 当 sessionId。
- `--json` 不改变落盘行为：`sessions/<id>/<id>.messages.json`、`sessions.db` 照旧写，
  所以会话采集 / 逐条消息流不受影响。
- 终稿按 20000 字截断（与 `RESULT_LIMIT` 一致），超长部分不进入 `resultText`。

**验证**：`bridge/test/cline-json.test.js`（9 个用例：成功流 / 认证失败 / 任意位置切块 /
末尾无换行 / 噪声行 / 终稿优先级 / 截断 / 非 JSON 回退）+ `command-json-mode.test.js`
（假 CLI 端到端：断言 `--json` 被传入、`done` 的 `resultText` 是 `OK` 而不是 JSON 原文、
error 事件判 failed、`json=false` 退回原始输出）。`cd bridge; node --test` 37 项全绿。


## 39. 重启等命令跑完：detached supervisor，而不是 `--keep-session`（2026-11-02）

**事故**：用户在手机命令 `cmd_c4a49f60fccf` 里要求重启 bridge（让 P12/P16/P13 生效）。
上一版用 `npm run restart -- --keep-session`：bridge 先回写命令 `failed`，再只杀 bridge
（不带 `/t`），理论上 cline 子进程能继续跑。实际结果（同一次 12:24 事故）：

- bridge 12:27:51 退出，新 bridge 12:27:53 起来；
- 子进程的 stdout/stderr 是 `stdio: ['ignore','pipe','pipe']`，**管道另一端在 bridge 上**；
- bridge 一死管道就断，cline 在 12:28:10 以 **exit code 1** 结束，发起重启的那轮对话断在半路；
- 新会话（下一次命令）看不到上一轮上下文，只能从 `docs/status.md` 和旧 `messages.json` 找回来。

**决策**：重启要「等当前命令跑完」，并且由一个**不属于任何命令进程树**的 supervisor 执行：

- `npm run restart:idle`（= `stop.mjs --restart --when-idle`）只做一件事：`spawn(detached)`
  一个 `scripts/restart-when-idle.mjs`，打印「已排队」，立刻返回。
- supervisor 轮询本机登记目录（`readEntries` + `inspectProcesses`），用
  `liveCommandEntries()` 只认「pid 存在 + 启动时间对得上」的命令（pid 被复用的不算）；
  进程查询失败按「还在忙」处理，宁可多等也不误重启。
- 空闲后先等 3 秒（`--grace`），再确认一次；这 3 秒里来了新命令就继续等。
- 确认空闲才调用 `stop.mjs --restart`，走正常的「先回写 → 再杀 → 再拉起」。
- 默认最多等 2 小时（`--timeout` 可覆盖，且只有显式传时才生效）；超时只写日志、
  **不动 bridge**。锁文件 `%TEMP%\cline-hub-cmd\restart-when-idle.json` 防连点排两个 supervisor。

**边界**：

- 这不是「热升级」：当前命令跑完之后、新命令进来之前有一个几秒空窗；期间手机发命令会
  落在一个正在关闭的 bridge 上，可能显示 `pending` 到新 bridge 起来。
- supervisor 只保证「不掐断已经在跑的命令」，不保证「重启期间新命令不丢」；命令是
  服务端认领语义，`pending` 的还会被新 bridge 领走。
- `--keep-session` 仍保留（极少数「进程还要跑、结果不要了」的场景），但注释与文档都写明
  它保不住会话，别当重启开关用。

**验证**：`bridge/test/idle-restart.test.js` 7 项（存活判定 / 立即返回 / 等最后一条结束 /
超时不误重启 / 查询失败不误重启 / 锁读写与存活判断）；本机实测排队后日志显示
`still busy {"commands":["cmd_c2e5d2d05eec"]}`，超时分支 `timeout, bridge left untouched`
且 bridge pid 未变、锁文件自动清理。

