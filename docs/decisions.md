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
