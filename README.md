# Cline Console

把 Windows 上 Cline（VS Code 插件 / CLI）的会话结果、执行过的命令和完成通知，收进自己部署的 Hub，
手机上随时看；也能从手机把 `plan` / `act` 指令发回 Windows 执行。

> 给长时间运行的 agent 补上「离开桌面之后」的那一段。
>
> **单租户、自托管**：一个 app token 能看全部设备、能给全部设备下命令，只适合自己用。
> 想给朋友用请各自部署一套。

## 1. 这个项目是做什么的

Cline 的任务动辄几十分钟，记录却只存在这台机器上：人一走开就不知道跑完没有，换个设备翻不到，
想让「接着干」还得回电脑前。Cline Console 补的就是这三段：

| 原来的问题 | 现在的做法 |
|---|---|
| 任务跑完 / 报错 / 被中断，人不在电脑前 | 终态立刻推到手机通知栏，结果原样回写，不用回桌面 |
| 会话散在本机 SQLite，跨设备翻不到 | 采集器增量读 `sessions.db` + `messages.json`，统一落到 Hub 的 Postgres，手机按项目 / 设备 / 时间翻 |
| 看完结果想让它接着干 | 手机写一句（`plan` / `act`）→ Hub 排队 → Windows 执行 → 输出回写 |

它**不做**模型调用、代码生成、云端账号体系，只负责「观测」和「下发」。

## 2. 怎么做的

三段式，没有消息队列、没有 K8s，出问题一眼能看出卡在哪一段：

| 部件 | 跑在哪 | 干什么 |
|---|---|---|
| **bridge** | Windows（常驻 Node 进程） | 采集 Cline 的会话与消息上报 Hub；轮询并执行远程命令 |
| **Hub** | 一台 Ubuntu（Caddy + Docker + Postgres） | 收数据、发 SSE、排队命令、鉴权与限流 |
| **App** | Android（Flutter） | 看会话 / 命令 / 动态，下发与取消命令 |

```
上行
  Cline hook ──→ ntfy（手机立刻响）
             └─→ bridge 127.0.0.1:3210 ──→ 入库
  bridge 按 updated_at 水位线扫 sessions.db + messages.json
        ──→ POST /api/v1/sessions + POST /api/v1/sessions/:id/messages
  Hub ──→ Postgres ──→ GET /api/v1/events（SSE）──→ App

下行
  App ──→ POST /api/v1/commands（可带 sessionId）
  bridge 轮询 GET /api/v1/commands/pending（服务端 FOR UPDATE SKIP LOCKED 认领）
        ──→ 交给 cline CLI 无头执行
        ──→ PATCH /api/v1/commands/:id 回写 running / done / failed / cancelled + 输出
```

**实时性三层兜底**：

1. App 在线时保持一条 SSE 长连接，新会话 / 新命令即时到达；断线自动重连，并退化为轮询。
2. 命令执行期间 App 挂一条静音前台服务（`dataSync`）保活，息屏 / 锁屏也能立刻收到结果。
3. App 被系统挂起期间，由 ntfy 把消息送到通知栏；回前台再补拉一次，补发错过的终态通知。

没有接 FCM / 厂商推送通道（ADR-51）：自托管场景下不想依赖 Google 服务或第三方 SDK，
代价是 App 被 ROM 冻结时通知会晚到（见「已知边界」）。

**技术栈**：Node ≥ 22.5（bridge）/ ≥ 20（Hub），两边都是零框架，唯一依赖 `pg`；
Postgres；Flutter；落地页纯静态、无构建。

## 3. 手机上能做什么（怎么用）

### 3.1 第一次打开

1. 装 APK：从[落地页](http://82.157.153.22/)下载最新版，或自己
   `cd app; flutter pub get; flutter build apk --release`。
2. 在 Hub 上（`server/` 目录）签发一个 **app 角色**的 token（只打印一次）：
   `npm run create-device -- --id phone --role app --name Pixel`。
3. App 向导里填 **Hub 地址** + **app token**。「测试连接」会同时验证地址可达、token 有效、数据库在线。
4. 进主界面：底部三个 Tab（会话 / 命令 / 动态），顶栏常驻 SSE 连接状态。

> 手机上只需要 app token。Windows 那台用 device token，写在 `bridge/config.json` 里，不用填到手机。

### 3.2 会话 Tab

- 默认按时间倒序；顶部搜索框按标题 / 结果内容搜（服务端搜索）。
- 往下翻自动加载下一页（游标分页），长会话不会一次拉几 MB 到手机上。
- 「按工作区浏览」按项目分组看；卡片带状态、模式、耗时、命令数、结果预览。
- 进详情：逐条消息流（用户原话 / 助手正文 / 执行过的命令）。正文与结果按 Markdown 渲染，
  命令输出保持终端原文。
- 详情里还能：看概览弹层（结果全文 / 用量 / 项目）、跳到会话开头、一键回到最新、
  长文折叠后展开全文、复制单条消息、复制整段对话。
- 「继续对话」= 带上下文新开一条命令（无头 CLI 接不上旧会话，见「已知边界」）。
- 会话里的「选择题」（`ask_question`）直接渲染成按钮，点选即下发。

### 3.3 命令 Tab

- 新建命令：选 `plan` / `act`（`yolo` 要 Windows 侧白名单放行）、选工作目录、写一句话。
- 状态实时更新：`pending → delivered → running → done / failed / cancelled`，执行中耗时每秒刷新。
- 卡片显示项目目录 + 来源设备；详情里有完整输出、`pid` / `runner` / 启动时间，
  还能复制一条排查命令（先核对 pid 与启动时间，再杀进程树）。
- 执行中可以「取消命令」：排队中的立即取消，执行中的由 bridge 按 commandId 杀进程树。

### 3.4 动态 Tab

Cline hook 事件流（任务开始 / 结束 / 失败 / 中断）。比会话采集更快到手机，用来确认「它现在在干什么」。

### 3.5 设置

| 项 | 作用 |
|---|---|
| Hub 地址 / token | 换服务器、轮换 token 时改这里 |
| 通知 | 「命令完成 / 失败」「会话结束」两个开关；Android 13+ 需先授权 |
| 锁屏也提醒 | 命令运行期间挂静音前台服务，息屏也能立刻收到结果（默认开） |
| 已接入设备 | 每台电脑的在线状态、会话数、待执行 / 执行中；可直接「设为默认」 |
| 版本与更新 | 当前版本、更新日志、检查更新（「打开下载页」或复制链接） |

### 3.6 多设备

接第二台电脑后，会话 / 命令 / 动态页顶部会多一排设备 chip（「全部设备」+ 每台，显示设备名），
只看某一台；只有一台设备时不出现。工作区分组按「设备 + 项目」，两台机器的同名项目不会混在一起。

## 4. 功能清单

### 4.1 Windows 采集与通知

- 增量采集：按 `updated_at` 水位线只读 `sessions.db`，读同目录 `messages.json` 拍平成逐条消息
  （用户原话 / 正文 / 工具调用 / 命令过程），重复上报走 upsert，不产生重复气泡。
- 采集内容：会话快照（终稿、状态、项目、耗时、用量）+ 消息流；单条上限 20000 字，超出标记 `truncated`。
- 断网不丢：上报失败进本地 outbox，恢复后补传。
- Hook 通知：任务结束 / 失败 / 中断 → ntfy（手机立刻响）+ 本机 hook server。
- 手工重发：`npm run resend`（补项目名 / 补全文 / 指定会话 / 最近 N 条 / 以另一台设备身份补历史）。
- 可选开机自启：启动文件夹 + VBS 隐藏窗口，不需要管理员权限。

### 4.2 远程命令

- 两种 runner（`commands.runner`）：`cline`（交给 Cline CLI 开新会话）/ `shell`（prompt 当脚本跑）。
- 模板化执行（`template`），脚本先落临时文件，避开引号转义；`--json` 解析结构化终稿与用量。
- 并发池：`commands.concurrency`（1–8，默认 1），不同工作目录可并行，同一目录强制串行。
- 超时强杀进程树；进程身份（`pid` + 启动时间）回写 Hub，本机另有登记文件。
- 取消：排队中直接 `cancelled`，执行中 `cancelling` → 杀进程树 → `cancelled`；已结束的拒绝回翻。
- 孤儿回收：Hub 上 `running` 但本机已无对应进程 → 回写 `failed: orphaned`，只改状态不盲杀。
- 优雅停 / 空闲重启：`npm run stop` / `restart` / `restart:idle`（先回写执行中的命令，再杀进程树）。
- 排障：`npm run ps`（commandId → pid，双校验，`--kill` / `--clean`）、`npm run reconcile --dry-run`、
  `npm run check:whitelist`。

### 4.3 Android 客户端

- 三个 Tab + 常驻 SSE 状态；断线自动重连，Web 预览没有 SSE 时退化为轮询。
- 会话：搜索、游标无限翻页、按工作区浏览、设备筛选、Markdown 渲染、长文折叠 / 全文页、
  消息复制 / 整段复制、概览弹层、回到最新、选择题点选。
- 命令：下发 / 取消、状态与实时耗时、项目目录与来源设备、完整输出、pid / runner、复制排查命令。
- 通知：命令终态与会话终态；同一任务 15 分钟内只提醒一次（命令 + 会话两条通道归并）；
  命令运行期间锁屏保活；后台期间结束的回前台补发。
- 设备：设备 chip 筛选、设备列表与在线状态、设默认下发目标。
- 设置：连接配置、通知开关、锁屏保活、版本与更新（内置更新日志 + 检查更新）。

### 4.4 Hub

- REST + SSE，`node:http` 裸写；唯一依赖 `pg`；单文件 Docker 镜像。
- Postgres 8 个幂等迁移：`devices` / `sessions` / `messages` / `hooks` / `commands`。
- 鉴权：token 只存 SHA-256；三种角色 `device` / `app` / `admin`。
- 读接口按设备隔离：device token 只能读自己的会话 / 消息 / 命令 / hook（跨设备 `403 device_mismatch`），
  SSE 也按设备过滤；app / admin 不传 `deviceId` 即全量。
- 每 IP 令牌桶限流（默认 120 突发 / 5 rps）+ 可选 CIDR 白名单；只监听回环，由 Caddy 反代。
- 会话列表游标分页 + 搜索；列表不返回全文，`resultText` / `commands` 只在详情给。
- 消息按 `seq` 增量续拉，长会话不用一次拉完。
- 设备列表：每台电脑的在线状态、会话数、待执行 / 执行中。
- App 更新清单 `GET /api/v1/app/latest` + APK 静态出口。
- 健康检查 `GET /api/v1/health`（含数据库延迟）；22 项冒烟覆盖鉴权、分页、搜索、命令闭环、设备、SSE。

### 4.5 安全边界

- **远程命令默认关闭**：`commands.enabled=false` 时命令一直留在 `pending`，不会被执行。
- **模式白名单**：模板默认只留 `plan`；`act` / `yolo` 不在 `allowModes` 里一律 `failed`。
- **工作目录白名单**：`workspaceWhitelist` 在**执行侧**也会校验，手机传 `C:\Windows\System32` 直接被拒。
- **可回收**：超时强杀进程树；取消按 commandId 精确杀；每条命令的生命周期带时间戳落库。
- **token 不进仓库**：只存哈希，`bridge/config.json` 与 `server/.env` 都在 gitignore 里。

## 5. 自己跑一套

| 你的情况 | 照着做 |
|---|---|
| 从空服务器跑通「手机 + 电脑」 | [`docs/self-host.md`](docs/self-host.md)（30 分钟，含验收清单） |
| 已有 Hub，想加第二台电脑 | [`docs/new-device.md`](docs/new-device.md)（15 分钟） |
| 要改接口 / 写客户端 | [`docs/api.md`](docs/api.md) |
| 想知道某个版本改了什么 | [`CHANGELOG.md`](CHANGELOG.md) |

最少三个部件：`server/`（Hub）+ `bridge/`（Windows）+ `app/`（Android）。
落地页在 `site/`，Caddyfile 与部署脚本在 `deploy/`，Cline hook 脚本在 `hooks/`。

## 6. 已知边界

- **单租户**：app token 能看全部设备、能给全部设备下命令；要多人用就各自部署。
- **命令是「下发」不是「终端」**：无头 CLI 只能 `-c <workspace>` 新开会话；`--id` 续会话要 TTY，
  所以 App 里的「继续对话」实际是新开一条带上下文的新会话。
- **通知不是系统级推送**：依赖 App 进程 / 前台服务 + ntfy。国产 ROM 若仍冻结进程，
  去系统设置里给 App「电池优化 → 无限制」，或关掉「锁屏也提醒」（回退到回前台补发）。
- **Web 预览只是预览**：没有 SSE，降级为 6 秒轮询。

## 文档

[`docs/README.md`](docs/README.md) 是索引：接口契约、自托管、第二台设备、实测笔记、
50 条 ADR（为什么这么设计）、主动中断记录。

## 许可证

[MIT](LICENSE)（Copyright © 2026 a9653）：随便用、改、商用、闭源分发，保留版权与许可声明即可，不提供担保。

基于本仓库改的东西请**另起名字**，别让人误以为是上游版本（MIT 没有商标条款，这句只是态度）。
