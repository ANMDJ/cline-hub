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


## 40. 取消命令：先 `cancelling`，bridge 按 commandId 杀，服务端防回翻（2026-11-02）

**背景**：P14。手机上下发错一条命令（例如 ACT 指错目录）时，唯一的手段是去电脑上
`npm run ps -- --kill`——用户碰不到电脑，命令就一直占着槽位。

**决策**：

- 状态机加一档 `cancelling`（迁移 007 加 `cancel_requested_at`，008 扩 `commands_status_check`）：
  - `pending` / `delivered`：Hub 直接置 `cancelled`，bridge 根本没 spawn，不需要杀进程；
  - `running`：置 `cancelling`，等 bridge 停完进程再回写 `cancelled`。
- bridge 的取消轮询放在 `tick()` 的**槽位检查之前**（只在本机有 children 时发请求），
  查询 `GET /api/v1/commands?deviceId=…&status=cancelling`，只匹配**自己** `children` 里
  的 commandId 再 `killTree`。不按 pid / 进程名猜，也不碰上一个 bridge 留下的进程。
- 领取到 spawn 之间还有窗口：`handle()` 开头花一次 `GET /api/v1/commands/:id`，
  已是 `cancelled` / `cancelling` 就直接不跑。查不到（Hub 抖动）时照旧执行——
  宁可多跑一条，也别把命令静默丢掉。
- 服务端防回翻：命令已是 `cancelled` 时 PATCH 原样返回；`cancelling` 期间迟到的
  `running`（补 pid / sessionId）保持 `cancelling`。否则会出现「点了取消，手机上却
  显示已完成」。
- bridge 重启后停在 `cancelling` 的命令由 `reconcile()` 收尾：进程没了回写 `cancelled`；
  进程还在且 **pid + 启动时间**都核对通过，才 `taskkill /t /f`（与 `npm run ps -- --kill`
  同一套规则，ADR-33）。
- 已结束的命令取消返回 409，不做状态翻转。

**代价与边界**：

- 取消延迟 ≈ `pollIntervalMs`（5 秒）；不是实时中断。
- 杀掉进程树后 cline 会话会翻成 `cancelled`，会话内容保留，但这一轮不会再有结论。
- 排队中取消只改命令状态：bridge 本地队列里那条在预检时被丢弃，不会产生 `running`。

**验证**：`bridge/test/command-cancel.test.js` 2 项端到端（真杀 PowerShell 进程树 /
排队中不 spawn）、`server/test/commands.test.mjs` 5 项（409 / 防回翻 / cancelling 保持）；
线上实测：取消已完成命令返回 409，`cancelling` 值在事务内写入再回滚通过。

## 41. 命令并发池：默认 1，同一个 workspace 强制串行（2026-11-02）

**背景**：P7。旧实现 `tick()` 里 `for (item of items) await handle(item)`，一次只能跑一条；
手机连着发两条，第二条要等第一条跑完（可能半小时）。

**决策**：

- `commands.concurrency`（1–8，默认 **1**）控制槽位数；默认 1 保持旧行为，
  想并行就显式配 2+。
- `tick()` 只做「领取 → 入队」，`pump()` 负责派发：`slots` 记录**已派发但可能还没 spawn**
  的命令（不能只看 `children`，否则同 workspace 的两条会同时通过检查）。
- **同一个 workspace 永远串行**：键取 `path.resolve(workspace).toLowerCase()`。
  两条 ACT 同时改一个仓库，冲突和「看不见对方改了哪一行」比慢更难查。
- 槽位满时不领取：领了也只能在本地排队，还会把 Hub 上的 `pending` 改成 `delivered`，
  手机上看不出区别。
- 停机时队列里的命令同样回写 `failed`（原因「bridge 正在关闭」），不能留在 `delivered`。

**代价与边界**：

- 队列只在内存里：bridge 重启后未开始的命令不会被自动续跑（Hub 上已是 `delivered`），
  需要重新下发；`shutdown()` 会尽量先把它们标成 `failed`。
- 同 workspace 的串行判定按**解析后的绝对路径**，不同写法（`C:\a\b` 与 `c:/a/b`）会归一。
- 并发数再大也不会超过 8：每条 cline 会话都吃 CPU，且日志会互相穿插。

**验证**：`bridge/test/command-pool.test.js` 2 项（不同 workspace 同时 running /
同 workspace 第二条 running 晚于第一条 done）。

## 42. 会话正文用 `flutter_markdown_plus` 渲染，命令输出不解析（2026-11-02）

**背景**：P8。模型回复里的标题、列表、表格、代码围栏在手机上是原始记号，读起来很累。

**决策**：

- 依赖 `flutter_markdown_plus`（`markdown` 的 Flutter 实现，维护活跃）；
  只有**会话正文 / 问题 / 会话结果**打开 `markdown: true`。
- 命令输出是终端回放（`SelectableText` + `kMono`），**不解析 Markdown**：
  `*`、`#`、`|` 在日志里是字面量，按格式吃掉会改变内容。
- 长消息（>900 字或 >12 行）折叠时仍是纯文本预览（`MarkdownBody` 不支持 `maxLines`），
  点「展开全文」的二级页才渲染 Markdown——既省布局开销，也让「看全文」有明确入口。
- 样式只覆盖必要项：正文跟随气泡字号、代码块等宽 + 深色底、链接信息色、
  标题按正文字号递进；其余交给 `MarkdownStyleSheet.fromTheme`。

**代价与边界**：

- APK 从 53.6MB → 55.2MB（`1.1.2` → `1.1.4` 实测）。
- 图片仍由 `MarkdownBody` 默认行为处理（网络图会被请求）；表格在窄屏不会横向滚动，
  超宽表格会被压缩换行。
- 渲染失败不应该影响阅读：`MarkdownBody` 解析异常会退化成纯文本段落，不会让整页崩掉。

**验证**：`app/test/markdown_test.dart` 4 项（标题不再显示 `##` / 默认不解析 /
表格窄屏不 overflow / 折叠后展开页仍是 Markdown）。

## 43. 读接口按设备隔离：device 看自己，app 看全部（2026-11-02）

**背景**：P3 的「多设备」还没做，但写接口早就用 `resolveDeviceId()` 限制 device 只能写自己；
读接口（`GET /sessions`、`/sessions/:id`、`/sessions/:id/messages`、`GET /commands`、
`GET /commands/:id`、`GET /hooks`）一直没加 `device_id` 条件。单设备时看不出问题，
接入第二台 Windows 后，任何一台的 device token 都能读到别人的会话正文和命令输出。
SSE 更直接：`broadcast()` 发给所有连接。

**决策**：

- `src/util.js` 新增 `readDeviceScope(client, requested)`，与写接口的 `resolveDeviceId()` 并列：
  - `device`：只能读自己；传别人的 `deviceId` 直接 `403 device_mismatch`
    （不静默改写，接错 token 时客户端能立刻发现）；
  - `app` / `admin`：不传 = 全部设备（手机端要跨设备看），传了 = 只看那一台。
- 六个读接口统一用它拼 `device_id = $n`；`GET /commands/:id` 另外对 device 做归属检查
  （别人的命令返回 403，与 PATCH 的语义一致）。
- SSE 用 `sseMayReceive(client, data)` 过滤：device 连接只收 `deviceId` 与之一致的事件；
  事件负载里没有 `deviceId` 时不发给 device（fail closed，宁可少推也不串）。
- `app` / `admin` 的 SSE 行为不变（全量）；bridge 不订阅 SSE，所以采集侧完全不受影响。

**代价与边界**：

- device 订阅 SSE 时会漏掉「没有 deviceId 的事件」；当前所有广播（session / messages /
  hook / command / command.update）都带 deviceId，后续新增事件必须带上。
- `GET /commands/:id` 对 device 返回 403 而不是 404：会泄露「这个 id 存在」，但这是
  内部单用户系统，可读的错误码更利于排障。
- 真正按设备分区推送（每台设备只连自己的流）要等多设备接入一起做；这次只保证「不串数据」。

**验证**：`server/test/scoping.test.mjs` 12 项（列表 / 详情 / 消息 / 命令 / hook 的 SQL
参数、跨设备 403、`sseMayReceive`、SSE 广播过滤、HTTP 层 403/200），
`cd server; node --test` 30 项全绿。

## 44. 路径归一化：同一个目录只有一种写法（2026-11-02）

**背景**：手机「工作区」页把同一个项目显示成两组：`...\chat\cline-hub` 32 条里的
31 条一组 + 1 条一组。查下来是 `workspace_root` 有两个来源——cline CLI 写
`sessions.db` 时用正斜杠（`C:/Users/.../cline-hub`），bridge 白名单与命令参数是人手填的
反斜杠（`C:\Users\...\cline-hub`）。项目识别（ADR-22）上线前采集的旧会话没有
`project` / `projectRoot` / `projectKind` 三列，App 只能退回「按绝对路径分组」，
而分组键只做了 `toLowerCase()`：分隔符不同的两个字符串就成了两个组。

**决策**：

- Hub：`src/util.js` 新增 `normalizeFsPath()`，只抹平「同一个目录的不同写法」：
  正/反斜杠、重复分隔符、尾部斜杠；**不动大小写**（Hub 也收 Linux 路径，
  `/Home` 和 `/home` 是两回事），UNC 的两个前导反斜杠保留，`C:\` 这种盘符根
  不退化成 `C:`（`C:` 的语义是「盘符当前目录」）。
- 写入侧先归一化：`POST /sessions`（`workspaceRoot` / `projectRoot`）、
  `POST /commands`（`workspace`）、`POST /hooks`（payload 里的 workspace）。
  这样不管 bridge / 客户端怎么传，库里只有一种写法。
- 读取侧再归一化一次（`toListItem()` / `toCommand()` / hook 列表）：
  历史行不回填也能立刻合并——为了改一个显示问题去批量改生产库不划算。
- App：`HubStore._pathKey()` 把路径折成 `c:/a/b` 形式的比较键，用于分组键与
  `knownWorkspaces` 候选去重；界面展示仍是服务端原样（`C:\a\b`）。
  `_groupKey` 的旧数据兜底分支（按绝对路径分组）也走这个键。

**代价与边界**：

- 大小写不统一：`C:\Users` 与 `c:\users` 在 Windows 是同一个目录，但库里仍存两串；
  App 的比较键会转小写，所以分组能合并（与改动前行为一致）。
- 只处理 Windows 风格路径（`X:\` / UNC）；POSIX 路径原样返回，避免把 `\` 当成
  可互换分隔符后误伤 Linux 上合法的反斜杠文件名。
- 旧会话的 `project` / `projectRoot` / `projectKind` 仍是空的：分组已合并，
  但组头只能显示目录名（`chat`）。要显示项目名需让 bridge 重新上报一次：
  在 `bridge/data/state.json` 里删掉这些 sessionId 的 `sentSessions` 指纹、
  置 `needsBackfill: true`，再 `npm run restart:idle`（会重扫最近 100 条，
  指纹未变的自动跳过）。**有 in-flight 命令时不要重启。**

**验证**：`server/test/paths.test.mjs` 6 项（归一化规则 + POST 入库参数 +
列表读取归一化）；`cd server; node --test` 36 项全绿。
`app/test/hub_store_test.dart` 新增 1 项（正/反斜杠两种写法并成一组、候选只剩一个）；
`cd app; flutter test` 58 项通过（5 项真机用例跳过）。

## 45. 手工重发：复用 bridge 的上报构造器，只推点名的会话（2026-11-02）

**背景**：ADR-44 之后，Hub 上的路径写法已经统一，但项目识别（ADR-22）上线前采集的
旧会话 `project` / `projectRoot` / `projectKind` 三列仍是空，App 只能退回按绝对路径
分组，组头显示的是目录名（`chat`）而不是项目名（`cline-hub`）。当时的补法是
「删 `state.json` 里这些 sessionId 的 `sentSessions` 指纹 + `needsBackfill` 再重启」，
问题是重启会掐断执行中的命令（ADR-36），而且会把最近 100 条全推一遍。

**决策**：

- 把「会话上报体怎么拼」从 `index.js` 抽成 `bridge/src/record.js`
  （`workspaceName` / `sessionState` / `effectiveStatus` / `toRecord` / `fingerprintOf`）。
  正常采集和重发脚本共用同一份，避免两条路径的字段集合漂移——重发一次反而把
  `project*` 写回空白，比不重发更糟。
- 新增 `bridge/scripts/resend.mjs`（`npm run resend`），只推**你点名的那几条**：
  `--session <id>` / `--missing-project` / `--recent <n>`，`--dry-run` 先看要发什么、
  `--no-messages` 只补快照。走的是和 bridge 完全一样的接口与鉴权，服务端按
  `sessionId` / `message_id` upsert，重复跑不会产生重复气泡。
- `--missing-project` 的判据是「`project` 与 `projectKind` 都为空」，**不是只看
  `project`**：散会话（`projectKind=loose`）的 `project` 本来就是空，按 `project`
  筛会把二十多条正常散会话也重推一遍。
- `--device` / `--token` / `--data-dir` 让同一台机器可以按另一台设备的身份补历史
  （多设备时不用去改 `bridge/config.json`）。

**代价与边界**：

- 重发用的是**本机** `sessions.db` + `messages.json`：Cline 已经清掉的会话（实测有
  6 条 11-01 的旧会话）本地没有源数据，脚本只能报「跳过」，补不了。
- `resultText` 按 `commands.cline` 那一套 `maxResultChars`（默认 4000）截断后上报，
  和正常采集一致；如果库里有更长的历史文本，重发会把它变短（与 bridge 平时的
  upsert 行为相同，不是脚本引入的）。
- 重发不碰 `state.json`：下一次正常扫描仍按原水位线走，不会因为重发而重复上报。

**验证**：`cd bridge; node --test` 53 项全绿（新增 `test/record.test.mjs` 5 项：
`workspaceName` / `toRecord` 的项目字段与 `prompt` 兜底 / `sessionState` 僵尸判定 /
`fingerprintOf`）；线上 `npm run resend -- --missing-project --dry-run` 能把 6 条旧会话
点名出来，但确认本地 `sessions.db` 已无这些行。

## 46. 命令耗时每秒刷新 + 设备过滤放 App 侧（2026-11-02）

**背景**：① 命令详情里「耗时 2m10s」在跑的时候一直是同一个数字——`CommandItem.duration`
虽然对 `running` 取 `DateTime.now()`，但它是 getter，列表只在数据变化（SSE 事件 /
轮询）时重建，空闲时几分钟不动。② 命令卡片只有设备名，看不出这条命令在哪个项目里跑。
③ 多设备后所有设备的会话 / 命令 / 动态混在一起，没法只看某一台。

**决策**：

- `app/lib/src/ui/widgets.dart` 新增 `ElapsedText`：`running && end == null` 时起一个
  1 秒 `Timer.periodic` 重建自己，翻成终态（`didUpdateWidget`）立刻停表；没有开始时间
  时显示 `—`。`MetaLine` 加一个 `trailing` 槽位专门放它——左侧文字过长先省略，
  耗时永远可见。
- 命令卡片的元信息改成「项目目录 · 设备 · 相对时间 · 耗时」，项目目录取路径末段
  （`workspaceLabel()`，两个分隔符都认、尾部斜杠不算一段、空值给「未指定目录」）；
  完整路径仍在详情页「指令」下面单独一行。
- 设备过滤（`HubStore.deviceFilter` + `visibleSessions` / `visibleCommands` /
  `visibleHooks`）放在 **App 侧**：服务端一次只给 50–60 条，为了筛设备再打一次请求
  还要和分页游标配合，不划算；`sessions` / `commands` / `hooks` 仍是全量，上拉分页与
  通知继续用全量。`DeviceFilterBar` 只在已知设备 ≥ 2 时渲染，单设备下界面完全不变。

**代价与边界**：

- 过滤只作用于**已加载**的数据：切到某台设备后，列表底部「到底了」说的是这一页加载完了，
  不是这台设备真的没有更多。
- `ElapsedText` 的秒表只在 Widget 存活时走：页面滚出屏幕（被回收）期间不刷新，
  回来会立刻按当前时间重算，不会累计错。
- 设备名仍来自「设置里的 deviceId + 已加载数据里出现过的 deviceId」，没有单独的
  `GET /devices`：Hub 侧的 `GET /api/v1/clients` 是 admin 专属，App 的 app token 拿不到。

**验证**：`cd app; flutter analyze` 无告警；`flutter test` 64 项通过（新增
`workspaceLabel` 2 项、设备过滤 1 项、`ElapsedText` 3 项）。

## 47. 新增 `GET /api/v1/devices`：设备列表给 App 读（2026-11-02）

**背景**：ADR-46 的设备过滤只能从「已加载的会话 / 命令 / 动态」里猜设备 id：

- 新接入、还没产生任何数据的电脑不会出现在 chip 里，用户以为没接上；
- 设备只有 id，没有名字（`clients.name` 存了但 App 拿不到）；
- 看不到在线状态、会话数、待执行 / 执行中命令，排障要回服务器敲 SQL。

Hub 原有 `GET /api/v1/clients` 是 **admin 专属**，手机上的 app token 调不动，也不能把 admin
token 发到客户端。所以新增一个只读、按角色收敛的接口。

**决策**：

- `server/src/routes/clients.js` 新增 `GET /api/v1/devices`，`auth: 'any'`：
  - 只返回 `role='device'`（电脑 / bridge）；`app` client 不算设备，避免 chip 里出现手机自己；
  - `device` token 只返回自己（沿用 ADR-43 的读隔离）；`app` / `admin` 返回全部；
  - 字段：`id` / `name` / `createdAt` / `lastSeenAt` / `sessionCount` / `commandCount` /
    `pendingCommands`（`pending+delivered`）/ `runningCommands`（`running+cancelling`）/
    `lastSessionAt` / `lastCommandAt`。计数用相关子查询，client 数量很少，不值得加缓存。
- App：`DeviceItem` 模型 + `HubApi.devices()`；`HubStore.devices` 进 `refreshAll()`，
  `knownDevices` 改成「设置 → Hub 设备列表 → 已加载数据」三层合并，老 Hub 没有该接口时
  仍能退回原来的猜法；`deviceLabel()` 用 `clients.name` 显示 chip。
- 设置页新增「已接入设备」卡片：在线（2 分钟内有 `lastSeenAt`）/ 离线、会话数、
  待执行 / 执行中、最近上报；可直接「设为默认」。

**代价与边界**：

- 在线判定是**启发式**：`last_seen_at` 由任意带 token 的请求触发（60 秒节流），
  bridge 每 5 秒轮询一次，所以 2 分钟窗口足够；但网络抖动会让它短暂显示离线。
- `lastSeenAt` 不区分「bridge 在跑」和「只是有人拿 device token 调了接口」；
  真正确认执行端活着仍要看 `npm run health`。
- 接口只读，不提供改名 / 删除；这些仍是 admin 的 `POST/DELETE /clients`。
- 仍然**没有**「用户 → 设备」授权：app token 能看全部设备（单租户），见 `docs/self-host.md` §7。

**验证**：`cd server; node --test` 39 项全绿（新增 `test/devices.test.mjs` 3 项：
app 看全部 / device 只看自己 / 无 token 401）；`cd app; flutter analyze` 无告警、
`flutter test` 67 项通过（新增 `DeviceItem` 2 项、设备列表合并 1 项）。

## 48. 同一条任务只提醒一次：命令终态与会话终态按 `sessionId` 归并（2026-11-02）

**现象**：手机上「同一个任务收到两条消息」，且**息屏后回到前台时最明显**：
先响一条「命令完成 · ACT」，约 30 秒后再响一条「会话完成 · cline-hub」。

**原因**：一次远程命令会写两次终态，描述的是同一件事：
1. bridge 执行结束立刻 `PATCH /commands/:id`（`done` / `failed`）→ SSE `command.update`；
2. bridge 的 `sessions.db` 扫描发现「命令开出来的那个会话」从 `running` 翻成终态，
   为了防抖要等 `COMPLETION_SETTLE_MS = 30_000`，稳定后才合成 `session_done` → SSE `hook`。

App 的去重键分别是 `cmd_x:done` 与 `hook:185`（ADR-35），两者互不相识，于是各弹一条。
息屏时 SSE 被 `pause()` 断掉，回前台先按「退后台时还在跑的命令」补发第一条，
随后 bridge 的 30 秒窗口到点、第二条通过重连后的 SSE 到达 —— 两条正好前后脚出现。

**决策**：
- `HubStore` 新增 `_notifiedTasks`（`sessionId → 首次提醒时间`，窗口 **15 分钟**）。
  命令通知与会话通知在弹之前都查它、弹之后写入；**先到哪条弹哪条，另一条静默**。
- 归并键用 `sessionId`：bridge 在 spawn 后会把新建会话的 id `PATCH` 回命令（ADR-25），
  所以命令侧也有这个字段；`session_done` 的 hook 由 `emitCompletion()` 带上 `sessionId`。
- 没有 `sessionId` 的数据（老的命令没回写、Cline 自己开的工作区会话）保持原行为：
  只有 `commandId:status` / `hook:<id>` 的单事件去重。
- 窗口外不合并：同一个会话几小时后重新跑一轮，应该再提醒一次。
- 不用「按标题/项目名相似度」之类的启发式：键必须是稳定 id，猜错会吞掉真正的提醒。

**代价与边界**：
- 归并表只在内存里，进程重启就清空；重启后如果恰好收到同一条 hook 的 SSE 重放，
  理论上还可能再弹一次 —— 但 Hub 的 SSE 不回放历史（见 `server/src/http.js`），所以不成立。
- 两条都到得很快时「先到先弹」，用户看到的是命令那条（带 mode / 失败原因），
  而不是会话那条（带项目名 + 摘要）；这是有意的：命令信息更精确。
- 不能归并「同一个会话被两次不同命令打开」的情况（实际上 bridge 每次都是新会话）。
- 真正的后台推送仍未解决：锁屏期间没有 SSE，只能靠回前台补发或 ntfy（见 P34 / ADR-35）。

**验证**：`app/test/notifications_test.dart` 新增 3 项 —— 命令先到 / 会话先到 / 回前台补发后
再收到 `session_done`，三种顺序都断言只弹 1 条；`flutter test` 71 通过 / 5 项真机用例跳过。

## 49. 会话分组键带上设备，组头显示来源机器（2026-11-02）

**问题**：工作区页的分组键只有项目路径（`projectRoot` / `workspaceRoot` / 项目名兜底），
两台电脑上的同名项目会被并成一个组：组头「12 条」混着两台机器的会话，
而且组头只有文件夹图标 + 项目名，看不出这批会话来自哪台电脑。

**决策**：
- `HubStore._groupKey()` 前缀 `<deviceId>|`：同一台机器上同一个目录仍然只算一组
  （路径键继续抹平大小写 / 分隔符 / 尾斜杠，ADR-44），不同机器的同名项目分成两组。
- `SessionGroup` 增加 `deviceId` 与 `loose` 两个字段；`loose` 取代工作区页里
  `key == '__loose__'` 的字符串比较（键现在带设备前缀，字符串比较必然失效）。
- `WorkspaceGroupHeader` 右侧加设备 Pill：`HubStore.deviceLabel(deviceId)`，
  有 `clients.name` 用名字，否则退回 id（ADR-47）。
- `SessionTile` 增加可选 `deviceLabel`：工作区页始终传，主列表只在已知设备 ≥ 2 时传，
  单设备用户界面与以前完全一样。
- `sessionGroups` 也走 `_onDevice()` 过滤，工作区页与主列表的设备 chip 行为一致。

**代价与边界**：
- 设备 id 是分组键的一部分，改名（`PATCH /clients`）不影响分组（用的是 id 不是 name）。
- 一台电脑换了设备 id（重装 / 换 token）会多出一组「同名项目」，这是正确的：
  Hub 也把它们当两台设备。
- 组头多一个 Pill，窄屏上项目名可用宽度变小；项目名是 `Flexible` + 省略号，
  不会挤掉右侧的条数。
- 主列表的 `设备 …` 只在多设备时出现：单人单机用户的卡片不增加噪音。

**验证**：`hub_store_test.dart` 新增「同名项目来自两台电脑时各成一组」；
`widget_test.dart` 的工作区页用例断言两个组头都显示 `localone`；
`flutter analyze` 无告警、`flutter test` 71 通过 / 5 跳过。

## 50. 锁屏期间的即时提醒：只在「有命令在跑」时挂 `dataSync` 前台服务（2026-11-03）

**问题**：`HomeShell` 在 `paused/hidden` 时主动 `_store.pause()` 断 SSE（ADR-35 的省电取舍），
于是锁屏期间命令跑完只能等回前台补发，或依赖 Windows hook 发的 ntfy。
「手机下发命令 → 锁屏等结果」这个最主要的用法，恰恰是本地通知发不出去的那段。

**为什么必须是「前台」服务**：Android 8 起，没有常驻通知的 Service 会被系统在几分钟内冻结；
只有 `startForeground()` 的服务（带一条用户可见、不可划走的通知）才被允许长期运行。
所以「后台保活」在 Android 上的唯一合法形态就是「前台服务」——它说的不是
「App 在前台」，而是「这个 Service 带一条通知，因此系统不冻结它」。

**决策：形态 B —— 只在这段时间里开**：

| 时机 | 动作 |
|---|---|
| 活跃命令数 0→1（`sendCommand` / 启动时 `refreshCommands` / SSE `command.update`） | `startKeepAlive('有 N 条命令正在执行')` |
| 活跃数跌回 0（done / failed / cancelled / cancelling 结束） | `stopKeepAlive()` |
| 鉴权失效（`LinkState.offline`，401） | 立刻停：SSE 都连不上，挂着没意义 |
| 用户关掉「锁屏也提醒」 | 立刻停（`syncKeepAliveNow()`） |
| 划掉最近任务 / Android 15 `onTimeout` / `dispose()` | 停（`stopWithTask="true"` + `STOP_FOREGROUND_REMOVE`） |

- **回前台不主动停**：停了以后再次进后台就是「后台启动 FGS」，Android 11+ 会直接拒绝
  （`ForegroundServiceStartNotAllowedException`）；命令跑的这几分钟留着常驻通知，
  正好当「还在跑」的状态指示。
- **不用 FCM**：自建单机场景没有 Google 服务（国产 ROM 普遍没有），也违背「零推送依赖」。
- **不引三方库**：`KeepAliveService.kt` 只用系统 API（~110 行），与 ADR-35 一致；
  仍不申请 `WAKE_LOCK`（前台服务本身已不被冻结）。
- **`START_NOT_STICKY`**：进程被杀后单独复活 Service 没有意义（Flutter engine 没了，SSE 回不来）。
- 通知走独立通道 `cline_hub_keepalive`（`IMPORTANCE_LOW`、静音、不亮、不显示角标），
  id 固定 `7301`，与 `HubNotification.id`（key 哈希）分开，互不覆盖。

**Dart 侧**：`HubNotifier` 新增 `startKeepAlive` / `stopKeepAlive`，**带默认空实现**——
`extends HubNotifier` 的实现不必改；`implements` 的 `NoopHubNotifier` / 测试记录器
不继承方法体，各自补两个空方法。旧 APK 装了新 Dart 只会 `MissingPluginException` 静默降级。
开关是 `SettingsStore.keepAliveEnabled`（`notify.keepAlive`，默认开）。

**代价与边界**：
- 命令运行期间多一条不可划走的常驻通知；可一键关掉，回到「回前台补发」的旧行为。
- 国产 ROM 若仍冻结进程，前台服务也救不了：README 排障表记「电池优化 → 无限制」。
- Android 15+ `dataSync` 有 6h/24h 累计上限：命令都是分钟级，到点只有卡死命令才可能触发；
  卡死时 P13 的 60 秒对账会把 `running` 回写 `failed`，活跃数归 0 自动退场。
- 手机本地通知与 Windows hook 的 ntfy 是两条独立通道：同一件事仍可能响两次
  （ntfy 覆盖的是「电脑上的会话」，包括手机没开 App 的情况，见 ADR-35）。

**验证**：`cd app; flutter analyze` 无告警、`flutter test` **78 通过 / 5 跳过**
（新增 7 条保活用例：拉起 + 幂等 / 终态收起 / 取消收起 / 关开关不拉起 / 平台不支持不碰 /
切换开关即时生效 / 后台保活期间不断流）。真机清单见 `docs/status.md` §0 的 P34。

## 51. 不接 FCM / 厂商推送：保活 + ntfy + 回前台补齐就够（2026-11-03）

**决策**：不引入 FCM、也不接华为 / 小米 / OPPO / vivo 等厂商通道和社交 App 的推送 SDK。
手机端的提醒只有三条路：App 活着（含命令运行期间的前台服务，ADR-50）时的本地通知、
Windows hook 发的 ntfy、回前台补拉补发。

**为什么**：

- **自托管单租户**：一个 app token 看全部设备，没有「服务端主动推给很多用户」的需求。
  FCM 那套「服务端持 service account 密钥 → Google 通道 → 设备」要多保管一份云凭据，
  而且国产 ROM 普遍没有 GMS，装了也收不到。
- **厂商通道的接入成本远大于收益**：每家都要注册开发者账号、实名、上架应用商店，
  每个 SDK 都会给 `flutter build apk` 添一个新的失败点。当前客户端刻意只保留
  `http` / `shared_preferences` / `flutter_markdown_plus` 三个依赖（ADR-31 / 42）。
- **真正要求「秒级」的场景已经被覆盖**：「手机上下了命令，锁屏等结果」最多几分钟，
  `dataSync` 前台服务（ADR-50）在这段时间里保证进程不被冻结、SSE 不断。
  其余场景（电脑上自己开的会话）晚几分钟可以接受 —— 这是 ADR-35 的省电取舍。
- **保活只在命令运行期间存在**：不是长期后台常驻，功耗与合规成本都可控，
  也不会出现「一个自建工具常年占着推送通道」的怪状态。

**代价（写进已知边界，不装作没有）**：

- ROM 冻结进程时通知会晚到，直到用户打开 App，或者 ntfy 那条先到；
- 没有「App 被彻底杀掉后仍能收到」的能力；
- 同一条任务可能响两次（ntfy 一条 + 本地通知一条，两条通道独立，ADR-50）。

**什么时候该推翻**：真要做团队版 / 多用户，或者要求「App 不在也能秒收」，
就得走 FCM（海外）或厂商通道 + 服务端 token 管理。那已经超出「自托管单机」的边界，
应该当成另一个项目，而不是给现在的客户端加 SDK。

**依据的实测**（2026-11-03，细节见 `docs/status.md` §0 P37）：

- ntfy 发布 `HTTP 200`（`id=dlyLaLiL8GFm`，0.76s），与 `hooks/_notify.ps1` 同一条路径；
- app token 连 `GET /api/v1/events` 27 秒内收到 `: connected`、2 条 `event: messages`、一次 `: ping`；
- 线上 APK（sha256 `4ecaf2f3…4173` / 55,256,496 B）里 `KeepAliveService` 的
  `foregroundServiceType=0x1`（dataSync）、`stopWithTask=true`，权限含
  `POST_NOTIFICATIONS` / `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_DATA_SYNC`。

**验证边界**：以上都是「不依赖真机」的部分；锁屏收通知 / 常驻通知消失 / 划掉任务
仍按 `docs/status.md` §0 的 P34 清单在手机上核对。

## 52. 手机发文件走「base64 JSON + Postgres bytea」，不引 multipart、不挂磁盘（2026-11-03）

**决策**：附件上传用 `POST /api/v1/attachments`，body 是
`{ deviceId, name, mimeType, data: base64 }`；内容存 `attachments.data bytea`，
命令只存 `attachment_id`。单份上限 `HUB_MAX_ATTACHMENT_BYTES`（默认 8 MB），
通过「按路由覆盖 body 上限」实现——其它接口仍是 4 MB。

**为什么**：

- Hub 是零框架的 `node:http`（ADR-1 / 2 的延续）。multipart 要引 busboy/multer，
  或者自己写 boundary 解析——为一个上传功能引入新的解析器与新的失败模式不值得；
  base64 走现成的 `readJsonBody()`，鉴权 / 限流 / 错误码全部复用同一条路径。
- Docker 里没有可信的持久目录：写 `bytea` 跟着数据库备份、迁移、删除（`clients`
  级联），不用再维护 volume + 清理任务。
- 命令只存引用，列表接口只多 4 个小字段（`attachment.id/name/mimeType/byteSize`），
  不违反 ADR-2「列表不返回大字段」。
- 附件必须属于目标设备（`attachments.device_id`），`device` token 只能下载自己的；
  否则手机可以借 B 电脑的附件让 A 电脑去跑本机文件。

**代价**：

- base64 让请求体膨胀 4/3：8 MB 的文件 ≈ 10.7 MB body（已按路由放宽，不污染全站）。
- 大文件会进 Postgres 的 WAL 与备份；单人自用的图片 / 文档级别没问题，
  真要传几百 MB 就得换成对象存储 + 预签名 URL，那是另一个量级的工程。
- 同设备 + 同名 + 同内容复用同一条记录（`sha256`），所以「改一个字节再发」会新增一条。
- **入库时间**：`attachments.created_at` 一律记录，并通过 `createdAt` 返回给 App（命令详情显示）。
  保留策略（按年龄清理）暂不做 —— 用户 2026-11-03 明确「先保留，之后再说」，
  以后做清理时直接按这一列算，不需要补数据。

**验证**：`cd server; npm test` 47 通过（新增 9 条：文件名清洗 / base64 校验 /
413 / 复用 / 设备归属 / 下载 scope / 只带附件下发）。

## 53. bridge 侧「先落盘、再给路径」，而不是把文件内容塞进 prompt（2026-11-03）

**决策**：bridge 领到带附件的命令后，先把内容下载到
`%TEMP%\cline-hub-cmd\incoming\<commandId>-<文件名>`，再把**绝对路径**和用户那句话
拼成 prompt 交给 `cline`；下载失败直接回写 `failed`。

**为什么**：

- prompt 有长度上限（Hub 4000 字、bridge 截到 8000），base64 一张图就撑爆；
  就算塞进去，模型读 base64 也不会「看到」图片。
- CLI 在目标 workspace 里执行，给绝对路径它才能自己 `read_file` / 打开；
  路径写错时用户还能在命令结果里一眼看到真实位置。
- 失败必须显式：带着「找不到文件」的 prompt 继续跑，模型会胡乱猜测，
  而手机端看起来「文件已发送」，这是最难排查的一类故障。

**边界**：

- 文件落在系统临时目录，不跟命令生命周期绑定；`%TEMP%` 由系统回收。
- `commandId` 做前缀，同一 workspace 并发跑多条带附件的命令不会互相覆盖。
- `MAX_ATTACHMENT_BYTES`（16 MB）比 Hub 默认上限（8 MB）宽一档，
  两侧默认值不一致时不会互相打架。

**验证**：`cd bridge; npm test` 59 通过（新增 6 条：文件名清洗 / 大小文案 /
prompt 拼装（有无说明）/ 下载落盘 / 404·空文件·超限）。

## 54. 浏览入口与设备筛选收进右侧抽屉，设置页不再重复放设备列表（2026-11-03）

**决策**：会话页顶部的「按工作区浏览」按钮、会话 / 命令 / 动态三页顶部的设备 chip
全部挪进 `HomeDrawer` 的「浏览」区；页面只在 `deviceFilter != null` 时渲染
`ActiveDeviceFilterBar`（「只看 X」+「看全部设备」）。设置页删掉「已接入设备」卡片，
只保留「默认执行设备（手填兜底）」。

**为什么**：

- 同一件事（看哪台电脑）原来有三个入口三份状态：页面 chips、抽屉设备列表、设置页设备卡片。
  抽屉与设置页各自 `refreshDevices()`，在线状态还可能不一致，用户会怀疑哪份是真的。
- 抽屉已经是常驻入口（P38 把设备列表挪了过来），浏览类动作放一起才符合「一划之内」；
  页面顶部还给按钮留位置，等于把最贵的屏幕高度花在低频操作上。
- 但筛选结果必须在页面上可见：抽屉是藏起来的，筛过之后列表少一半，
  用户第一反应是「数据丢了」。所以保留一条只在筛选时出现的提示条，而不是把 chip 搬回去。

**边界**：

- chip 只影响 `HubStore.visible*`（本地筛选），不改 `settings.deviceId`；
  抽屉里点设备行才是「设为默认下发目标」。两件事在抽屉里用文案分开写。
- 只有一台已知设备时不渲染 chip（没什么可筛的）；此时若残留筛选，页面提示条仍能清掉。
- 设置页的手填框保留：设备还没上报过（`GET /api/v1/devices` 里没有）时抽屉里点不到它，
  仍需手动填 id（首次接入 / 换了新机器）。
- 「按工作区浏览」的 push 由 `HomeShell` 提供回调（先 pop 抽屉再 push），
  抽屉自身不持有 Navigator 生命周期；与「设置」同一套做法。

**验证**：`cd app; flutter analyze` 无告警、`flutter test` **88 通过 / 5 跳过**。
`attachment_test` 的抽屉用例扩展到「按工作区浏览 / chip 只筛不改默认 / 离线显示多久没上报」；
`widget_test` 新增 2 条：「提示条只在筛选时出现，可一键看全部」与「设置页不再重复放设备列表」。
顺手把 `SectionCard` 的内容包了一层透明 `Material`：卡片里的 `SwitchListTile` 原来会触发
「ListTile background color or ink splashes may be invisible」的 debug 断言（只在打开设置页时
出现；release 不报但水波纹确实画不出来）。

---

## 55. 外部审计文档先核事实再采纳：只按「能落到 文件:行」的结论排期（2026-11-03）

**背景**：用户从手机发来一份 `cline-hub 安全审计与加固建议.docx`（自称「基于仓库文档、目录结构与
公开代码的静态审计」，明确未做动态渗透、未逐行审计），给了 6 条风险 + 一张代码审计检查表，
并问「是否按这个文件调整项目」。

**决定**：逐条回代码复核后**只采纳 4 项**（P40 XFF 取最后一段 / P41 SSE 短期 ticket /
P42 命令租约自动回收 / P43 SSE 纵深防御），其余明确不做；本轮**只写文档**
（`docs/security-review.md`），不改任何行为代码。

**为什么**：

- 它的事实准确率约 6/10。说对的 7 条（SKIP LOCKED 短事务、token 只存哈希 + `timingSafeEqual`、
  单租户、线上只监听回环、无租约只能手动 reconcile…）说明作者确实读过仓库；
  但有硬错：**「SSE 缺少心跳」其实有**（`HUB_SSE_HEARTBEAT_MS` 默认 25s，`http.js:229-238`）、
  **CVE-2026-59723 被写成 9.7 且「影响 @cline/cline-hub」**（实为 8.8 / `AV:A`，
  影响 `cline dashboard` 的 `/browser` WebSocket，修复版 3.0.30，本机 `cline 3.0.74` 已修）、
  **「XFF 采信条件写错」实为「取第一段」错**（`net.js:21-27` 的回环判断正是它建议的写法）。
- 它把 Origin 校验定为 🔴 高的前提在本项目不成立：凭据是 `Authorization: Bearer` / `?token=`，
  没有浏览器自动携带的 cookie，恶意页面拿不到 token 就开不了 SSE。照单全改会先花两天修一条
  不可利用的问题，而它**漏掉了**真正该修的「SSE token 在 URL 里 → 进 access log」
  （`app/lib/src/data/hub_api.dart:389-393`）。
- 反过来，它的「命令租约」「状态回写用条件更新」方向是对的，且用户踩过「命令卡 running」的坑，
  所以保留成 P42 / P41 之后的顺位。

**边界**：

- 审计文档不是事实源：任何断言必须能落到 `文件:行号` 或一条可复现命令；落不到就当猜想，不进待办。
- 同类 CVE 要比三件事 —— 产品名、修复版本、凭据模型；只要一条不同就不构成「同构风险」。
- 已拍板不做的（多租户、Hub 侧按 device 限并发、token 过期/强制轮换、把 health 全关掉）
  连同理由写在 `security-review.md` §5，下次不必重复讨论。

**验证**：`security-review.md` §4 的 4 项实测都可复现（`clientIp()` 对
`X-Forwarded-For: 1.2.3.4, 203.0.113.9` 返回 `1.2.3.4`、CVE API 原文、`cline --version`、
`flutter analyze` 无告警 + `flutter test` 88 通过 / 5 跳过）。本轮改动只落在 `docs/` 与
`AGENTS.md`（工作区里另有 P39 的未提交 App 改动，属于上一轮、与本轮无关）。

