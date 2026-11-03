# AGENTS.md · 新会话从这里开始

> 给「刚打开这个仓库、不知道要干什么」的 AI 会话（以及三个月后的你）。
> **先读完这一页再动手**；需要细节时按文末「文档地图」跳转，不要凭印象猜。
> 最后核对：2026-11-02（+08）。可复现的实测值见 [`docs/status.md`](docs/status.md) §1。

## 0. 30 秒看懂

Cline Console：把 Windows 上 Cline（VS Code 插件 / CLI）的会话结果、执行过的命令、完成通知
采集到自建 Hub，手机上随时看；也能从手机下发 `plan` / `act` 命令回到 Windows 执行。

| 项 | 值 |
|---|---|
| 仓库根 | 当前目录（下文用 `<仓库>`；示例 `%USERPROFILE%\.cline\data\workspaces\chat\cline-hub`） |
| 分支 / 远端 | `master`；远端 `origin` = `git@github.com:ANMDJ/cline-hub.git`（**公开**；服务器 IP 本就在 DNS 里，未做脱敏） |
| 线上入口 | `https://hub.littlewish.top:8443`（备案期的临时 HTTPS 端口） |
| 服务器 | `ubuntu@82.157.153.22`（Ubuntu 22.04 / Caddy 反代 / Docker） |
| 技术栈 | Node ≥20（零框架，唯一依赖 `pg`）/ Postgres / Flutter 3.47 / 纯静态站点 |
| 许可证 | MIT（见 `LICENSE`） |

## 1. 开工前先跑这三条（只读，约 10 秒）

```powershell
git status --short; git log --oneline -5
(Invoke-WebRequest -UseBasicParsing https://hub.littlewish.top:8443/api/v1/health).Content
try { (Invoke-WebRequest -UseBasicParsing http://127.0.0.1:3210/health).Content } catch { 'bridge 没在跑' }
```

| 结果 | 含义 / 下一步 |
|---|---|
| `git status` 有改动 | 先问清楚这些改动是谁的、要不要保留，**别直接 checkout / reset** |
| Hub 返回 `{"ok":true,...}` | Hub + Postgres 活着；顺便看 `db.latencyMs` |
| Hub 超时 / 证书错 | 服务器或入口有问题 → `docs/status.md` §5；服务器操作看 `deploy/README.md` |
| bridge 返回 `cline-bridge` | 采集器在跑（当前是**手动**启动，不开机自启） |
| bridge 连不上 | 正常态之一：`bridge/config.json` 的 `commands.enabled` 是总开关，没起就收不到远程命令 |

## 2. 目录地图

| 路径 | 是什么 | 什么时候进 |
|---|---|---|
| `hooks/` | Cline 全局钩子（`.ps1`），任务结束/失败/中断时推 ntfy + 本机 bridge | 改通知文案、编码 |
| `bridge/` | Windows 常驻进程：收 hook、增量读 `sessions.db` + `messages.json`、上报 Hub、执行远程命令 | 采集与执行逻辑 |
| `server/` | Hub：`node:http` 裸写的 REST + SSE + Postgres | 加接口、改鉴权/限流 |
| `app/` | Flutter 客户端（Android 为主，Web 仅预览） | 手机端 UI / 状态层 |
| `site/` | 开源落地页，纯静态，Caddy `file_server` 直出 | 改文案 / 发布前自检 |
| `deploy/` | Caddyfile、ntfy 配置、部署 runbook、Windows 自检脚本 | 上服务器、排障 |
| `docs/` | API 契约、实测记录、ADR、服务器准备清单、**status.md** | 动手前查事实 |
| `.secrets/` | device / app token、历史前缀（**gitignored**） | 只读引用，任何输出里都不要打印明文 |

## 3. 数据流（两条链路，别搞混）

```
上行（采集）
Cline hook → hooks/_notify.ps1 → ntfy（手机立刻响）+ 127.0.0.1:3210/hook
bridge 轮询 %USERPROFILE%\.cline\data\db\sessions.db（updated_at 水位线）
       → 读 messages.json → 拍平成逐条消息 → POST /api/v1/sessions + /messages
       → Hub 落 Postgres → GET /api/v1/events（SSE）推给 App

下行（远程命令）
App → POST /api/v1/commands（可带 sessionId）
    → bridge 轮询 GET /api/v1/commands/pending（服务端 FOR UPDATE SKIP LOCKED 认领）
    → cline CLI 无头执行（新开会话，见 §5）
    → PATCH /api/v1/commands/:id 回写 running/done/failed + 输出
```

## 4. 常用命令

```powershell
# bridge（Windows 采集器）
cd bridge; node src/index.js            # 常驻；npm start 等价
cd bridge; npm run once                 # 只跑一轮，调试用
cd bridge; npm run health               # 本机 3210 健康检查
cd bridge; npm run ps                   # commandId → pid（pid + 启动时间双校验）
cd bridge; npm run stop -- --reason "升级 bridge" # 优雅停：先回写执行中的命令，再杀进程树
cd bridge; npm run restart -- --reason "换配置"   # 停 + detached 重启（等价 Start-Process）
cd bridge; npm run restart:idle -- --reason "升级 bridge" # 等执行中的命令跑完再重启（在命令里发起重启时用这个）
cd bridge; npm run reconcile -- --dry-run # 哪些 running 命令已经没有进程（不改状态）
cd bridge; npm run check:whitelist      # 校验 workspaceWhitelist 配置
cd bridge; npm run resend -- --missing-project --dry-run # 手工重发：补旧会话的快照/消息（本地还有源数据才行）

# server（Hub）
cd server; npm install; npm run migrate
cd server; npm run create-device -- --id phone --role app --name Pixel
cd server; npm run smoke                # 端到端冒烟

# app（Flutter）
cd app; flutter pub get; flutter test   # 88 项通过（5 项真机用例跳过）
cd app; flutter run -d chrome           # 桌面预览（Web 没有 SSE，降级为轮询）
cd app; flutter build apk --release     # → build/app/outputs/flutter-apk/

# site（纯静态）
node site/check-site.mjs                # 标签 / CSS / 引用 / 锚点自检

# 全链路自检（Windows）
powershell -NoProfile -File deploy/windows/verify-hub.ps1
```

启动 Windows 后台进程**只用** `Start-Process`；不要用 Git Bash 的 `nohup node ... &`（会把 Cline 的终端 shell 一起带走）。
停 bridge 用 CommandLine 精确匹配，别按进程名杀：

```powershell
Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
  Where-Object { $_.CommandLine -like '*src/index.js*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

要看/停**某一条 App 命令**同理，不要按 `node.exe` / `cline` 杀：
`cd bridge; npm run ps` 给出 `commandId → pid`，`npm run ps -- --kill <commandId>` 会先用
「pid + 启动时间」双校验再杀进程树；bridge 崩溃留下的孤儿用 `npm run ps -- --clean` 收。

## 5. 硬约束（违反会直接出事）

1. **仓库里不出现真实 token / 口令**。`bridge/config.json`、`server/.env`、`.secrets/` 都已 gitignore；
   token 只在 `npm run create-device` 时打印一次，库里存 `sha256`。
2. **`.ps1` 保持 ASCII-only**：Windows PowerShell 5.1 会把无 BOM 的 UTF-8 当 ANSI，中文直接乱码。
   Hook 脚本任何异常都 `exit 0`，永不阻塞 Cline。
3. **行尾交给 `.gitattributes`**（整体 `eol=lf`，`*.ps1`/`*.vbs` 用 CRLF），别手改。
4. **远程命令默认关闭**：`commands.enabled=false`、`allowModes` 模板只留 `plan`；
   `workspaceWhitelist` 在**执行侧**也会校验，手机传 `C:\Windows\System32` 直接 `failed`。
5. **无头跑 cline 的三个坑**：`-c <workspace>` 新开会话（`--id` 续会话要 TTY，`resume=false`）；
   必须显式 `-P <provider> -m <model>`；prompt 只有一个不含空白的词会被当子命令（ADR-21/24/27）。
6. **会话列表不返回全文**，`resultText` / `commands` 只在详情接口给（ADR-2）。改列表别把大字段塞回去。
7. **SSE 反代必须 `flush_interval -1`**，否则事件会被 Caddy 缓冲（ADR-5）。
8. 改完行为要**同步文档**：模块 README + 根 README 对应段落；新的「为什么」追加到
   `docs/decisions.md`（ADR 编号递增，不修改旧条目）；现状变化更新 `docs/status.md`。
9. **停 bridge 之前先停任务**：用 `cd bridge; npm run stop -- --reason "..."`（先回写执行中的
   命令为 `failed`，再杀进程树，最后退出）。`Stop-Process` / `taskkill /pid` 是硬杀，Node
   收不到 `SIGTERM`，手机上的命令会卡「执行中」。**在命令里发起重启**用
   `npm run restart:idle`（等命令跑完）；`--keep-session` 保不住会话（bridge 一死管道就断，
   cline 十几秒后 exit 1）。**每次主动中断都要在
   [`docs/interruptions.md`](docs/interruptions.md) 追加一条**（为什么杀 / 影响了谁 / 怎么恢复）。

## 6. 一次任务的推荐流程

1. 跑 §1 三条命令，确认基线。
2. 看 [`docs/status.md`](docs/status.md) §0「现在要做什么」——**用户没填就先问，不要自己找活干**。
3. 只读相关文档：接口 → `docs/api.md`；实测事实与坑 → `docs/bridge-notes.md`；
   为什么这么设计 → `docs/decisions.md`。
4. 小步改，改完立刻验证（对应模块的测试 / 自检脚本，见 §4）。
5. 收尾：更新 `docs/status.md` 的变更日志 + 相关文档，`git status` 复核没有把 token / 日志带进去。
6. **收尾必须交「下一步计划」**：先写清这次做了什么 / 验证结果 / 遗留风险，再按
   [`docs/status.md`](docs/status.md) §0 的顺序列 3~5 条后续待开发项，并标出哪条能立刻做、
   哪条要等真机或用户拍板。**计划只列不擅自开工** —— 用户看完再决定下一轮做什么。

## 7. 常见故障速查

| 现象 | 先查 |
|---|---|
| 手机列表空 | bridge 没跑 / outbox 积压（`bridge/outbox.json`）/ Hub 没数据 |
| 命令一直 `pending` | `commands.enabled`、`allowModes`、bridge 进程 |
| 命令 `failed: workspace not allowed` | `workspaceWhitelist`（跑 `npm run check:whitelist`） |
| 命令卡 `running` 不结束 | cline 在等 stdin（`spawn` 必须 `stdio: 'ignore'`）/ 超时被杀 / bridge 重启过 → `npm run reconcile -- --dry-run` |
| 命令卡 `running` 且是刚重启过 bridge | 是不是硬杀过（`Stop-Process`）？硬杀不回写状态 → `npm run reconcile`；以后用 `npm run stop -- --reason "..."` |
| 顶栏一直「连接中」 | 旧 APK；SSE 被反代缓冲（`flush_interval -1`） |
| `401 invalid_token` | token 被轮换，重新签发并同步到 App |
| `404` 且 body 为空 | 旧文档里的 `/_h/<前缀>` 入口已退役，用 `https://hub.littlewish.top:8443` |
| 证书报错 / 2027-01 之后全挂 | 证书续期必须改 DNS-01，见 `docs/status.md` P1 |

## 8. 文档地图

| 文档 | 内容 | 什么时候读 |
|---|---|---|
| [`docs/README.md`](docs/README.md) | 文档索引与阅读路径 | 第一次来 |
| [`docs/status.md`](docs/status.md) | 现状快照、待办、验收清单、变更日志 | **每次开工** |
| [`CHANGELOG.md`](CHANGELOG.md) | 版本更新日志（按版本；按日期的开发过程在 `status.md` §8） | 想知道「哪个版本改了什么」 |
| [`README.md`](README.md) | 项目介绍、手机端用法、功能清单 | 第一次了解 / 对外介绍 |
| [`docs/api.md`](docs/api.md) | Hub v1 接口契约（鉴权 / 错误码 / 请求响应） | 改接口、写客户端 |
| [`docs/self-host.md`](docs/self-host.md) | 从零自托管：服务器 → 电脑 → 手机的完整闭环 | 第一次部署、教别人部署 |
| [`docs/new-device.md`](docs/new-device.md) | 接入第二台 Windows（device token / bridge / 多机边界） | 加电脑、排查设备不上线 |
| [`docs/bridge-notes.md`](docs/bridge-notes.md) | 本机实测事实：Cline 数据位置、messages.json 结构、安全排查 | 改采集 / 怀疑环境 |
| [`docs/decisions.md`](docs/decisions.md) | 55 条 ADR：「为什么这么做」 | 想推翻某个设计之前 |
| [`docs/security-review.md`](docs/security-review.md) | 外部安全审计文档的逐条复核（哪些对 / 哪些错 / 漏了什么）+ 采纳计划 P40–P43 | 收到外部审计、漏洞报告，或要动鉴权 / SSE / 反代之前 |
| [`docs/interruptions.md`](docs/interruptions.md) | 主动中断记录：为什么杀 bridge / 杀了谁 / 怎么恢复 | 开工前、要重启 bridge 时 |
| [`docs/server-prep.md`](docs/server-prep.md) | 服务器从零准备（Docker / Postgres / Caddy / ntfy） | 换机、重建 |
| [`deploy/README.md`](deploy/README.md) | 部署 runbook、回滚、常见故障 | 上服务器 |
| [`server/README.md`](server/README.md) · [`app/README.md`](app/README.md) · [`site/README.md`](site/README.md) | 各模块的跑法与取舍 | 进模块前 |