# 现状与待办（status）

> 每次开工先读 §0；动手前核对 §1 的实测值。最后更新：**2026-11-02（+08）**。

## 0. 现在要做什么

**2026-11-02 重新排过顺序**：先做「看得见、杀得准」（进程身份 + 归口），再做并发。
并发池（P7）没有进程身份会很难收场：单槽位杀进程、按 cwd 猜会话、孤儿无法定位。
做完一项就把勾打上、并在 §8 记一行。

| 顺序 | 编号 | 内容 | 状态 |
|---|---|---|---|
| 1 | P11 | **Step 1：命令进程身份上 Hub**（migration 006 加 `pid` / `pid_started_at` / `runner`；bridge spawn 成功立刻回写；App 命令详情显示 pid + 复制排查命令） | ✅ 已上线（migration 006 + Hub；线上 `GET /commands` 已返回三字段） |
| 2 | P12 | **Step 2：本机登记 + 精确归口**（`%TEMP%\cline-hub-cmd\running\<id>.json`；`npm run ps` 查/杀/清理；`stop()` 杀掉全部子进程，不再只有一个槽位） | ✅ 已上线（bridge 12:27 重启后生效） |
| 3 | P13 | 卡死命令回收：`running` 但进程已不在 / pid+启动时间对不上 → 回写 `failed: orphaned`，**不盲杀** | ✅ 已上线（启动对账已跑，清掉 `cmd_c4a49f60fccf` 的残留登记；每 60s 一次） |
| 4 | P6 | bridge 用 `cline --json` 取结构化结果（终稿 / 失败原因 / 用量；`taskId` 不是会话 ID） | ✅ 已生效（12:51 when-idle 重启后走 `--json`；ADR-38） |
| 5 | P18 | **重启不掐断当前命令**：`npm run restart:idle` 交给 detached supervisor，等执行中的命令跑完再重启（`--keep-session` 保不住会话：bridge 一死，子进程的 stdout 管道就断了） | ✅ 已上线（12:51 用 `--grace 15000` 重启成功；ADR-39） |
| 6 | P7 | 命令并发池：`commands.concurrency` + 同 workspace 强制串行（依赖 P11–P13 / P6） | ✅ 代码 + 测试完成（`concurrency` 默认 1；ADR-41），待 bridge 重启生效 |
| 7 | P14 | 手机取消命令：`POST /api/v1/commands/:id/cancel`，bridge 按 commandId 精确杀 | ✅ Hub 已上线（迁移 007/008）；bridge / App 待重启/安装 |
| 8 | P8 | 详情页 Markdown 渲染（`flutter_markdown_plus`） | ✅ 已发布 `1.1.4+6`（ADR-42） |
| 9 | P15 | 手机端系统通知：命令完成/失败 + 会话终态（原生 MethodChannel，设置页可开关/授权） | ✅ 已发布 `1.1.2+4`（装到手机后生效） |
| 10 | P2 | PLAN/ACT 选中态真机核对对比度（需要手机，用户侧） | ⏳ 代码完成，待真机核对 |
| 11 | P16 | 停 bridge 前先停任务：`POST /admin/stop` + `commandWorker.shutdown()`（先回写 running，再杀进程树）+ `npm run stop` / `npm run restart` + `docs/interruptions.md` | ✅ 已上线（bridge 12:27 起为新版本；未在本会话里自杀验证） |
| 12 | P17 | App 自动更新可直接「打开下载页」：原生 `ACTION_VIEW`（`link_launcher.dart` + `MainActivity`），复制链接保留 | ✅ 已发布 `1.1.4+6`（与 P8 一起发版） |

已完成并上线的：P0 / P1 / P3 / P4 / P5 / P9 / P10（P3、P9 已部署，P5、P10 已发布 1.1.1）。

### Step 1 + Step 2 落地记录（2026-11-02）

- Hub：`commands` 新增 `pid` / `pid_started_at` / `runner`（migration `006_command_process.sql`）；
  `toCommand()` 输出 `pid` / `pidStartedAt` / `runner`；PATCH 用 `coalesce` 写入，非法 pid 直接 400。
- bridge：`registerChild()` 在 spawn 成功时同时写本机登记文件、更新 `Map<commandId, child>`、
  PATCH `running + pid + pidStartedAt + runner`；`unregisterChild()` 在进程结束时删登记。
  `stop()` 改为遍历全部子进程（旧实现只有一个 `state.child` 槽位）。
- 本机：`bridge/src/command-registry.js`（读/写/清理 + `sameProcessStart()` 纯函数）+
  `bridge/scripts/ps.mjs`（`npm run ps` / `--json` / `--kill <id>` / `--clean`）。
- App：`CommandItem` 增加 `pid` / `pidStartedAt` / `runner`，命令详情显示 `pid · runner · 启动于`，
  并提供「复制排查命令」（先 `Get-Process` 核对启动时间，再 `taskkill /pid ... /t /f`）。
- 验证：`cd bridge; node --test`（9 项）、`cd server; node --test`（13 项）、
  `cd app; flutter analyze; flutter test`（44 项，5 项真机用例跳过）、`node site/check-site.mjs`。
  本机实测 `npm run ps`：能列出 pid、双校验 ✓、识别孤儿（bridge 已退出）、`--kill` 成功后登记消失。

### P13 + P15 落地记录（2026-11-02）

- **P13 孤儿回收**：`command-worker.reconcile()` 在 bridge 启动时 + 每 60 秒各跑一次，
  取 `GET /api/v1/commands?deviceId=…&status=running`，用 `classifyRunningCommand()`
  （`owned` / `recent` / `alive` / `orphaned`）判断，只把 `orphaned` 回写成
  `failed` + 「原来的执行进程不在了」；**不杀进程**。
  证据优先本机登记，登记被清理时退回 Hub 的 `pid` + `pidStartedAt`。
  新增 `bridge/src/process-info.js`（与 `npm run ps` 共用同一套 pid 查询）、
  `bridge/scripts/reconcile.mjs`（`npm run reconcile [-- --dry-run]`）。
- **实测**：03:40 领养的 `cmd_3ced4a851f4c` 在 03:47 bridge 重启后卡了 19 分钟，
  对账一次即回写 `failed`（`finishedAt=03:59:57`），同时当前在跑的 `cmd_3cbc40a4c1e0`
  因为登记 + pid 双校验通过被正确跳过。
- **P15 通知**：`HubNotifier` 接口 + `LocalHubNotifier`（Android 原生 MethodChannel）+
  `NoopHubNotifier`（Web / 测试）；`MainActivity` 建 `cline_hub_events` 通道、
  请求 `POST_NOTIFICATIONS`、发可点开 App 的通知。触发点只有命令 `active → done/failed/cancelled`
  与 bridge 合成的 `session_done/session_failed/session_cancelled`，同一键只弹一次。
  设置页新增「通知」卡片（两个开关 + 请求权限）；后台期间结束的命令在回前台时补发。
- **验证**：`cd bridge; node --test`（15 项）、`cd app; flutter analyze`（No issues）、
  `cd app; flutter test`（新增 4 个通知用例）、`node site/check-site.mjs`。

### P16 + P17 落地记录（2026-11-02）

- **P16 先停任务再杀进程**（为什么：`cmd_3ced4a851f4c` 卡了 19 分钟）：
  - `hook-server` 新增 `POST /admin/stop`（只认回环地址），先回 202 再触发 `shutdown(reason)`。
  - `command-worker.shutdown()`：停领取 → 并发 `PATCH failed`（`interruptionErrorText()`，
    每条 3 秒超时）→ 杀进程树 → 交给 `index.js` 退出；`handle()` 不再覆盖已回写的状态。
  - 新增 `bridge/scripts/stop.mjs`：`npm run stop -- --reason "..."` /
    `npm run restart -- --reason "..."`（detached 拉起，等价 `Start-Process`）。
  - 新增 `docs/interruptions.md`：每次主动中断写「为什么杀 / 怎么杀 / 影响了谁 / 怎么恢复」；
    `AGENTS.md` §5 加了第 9 条硬约束。
- **P17 下载地址直接开浏览器**：`app/lib/src/data/link_launcher.dart`（`isHttpUrl()` + `open()`）
  + `MainActivity` 新通道 `top.littlewish.cline_console/links` 的 `openUrl`（只接受 http/https）；
  设置页「版本与更新」改成「打开下载页」+「复制链接」，打不开浏览器时自动复制并提示。
  版本 `1.1.3+5`；ADR-36/37。
- **验证**：`cd bridge; node --test`（23 项通过，含「假 Hub + PowerShell 睡 30 秒」的
  shutdown 集成用例：断言 `failed` 的 PATCH 在杀进程之前发出、且不被 `exit code -1` 覆盖）、
  `cd app; flutter analyze`（No issues）、`cd app; flutter test`（51 项通过）。
  **线上 bridge 还是旧版本**（没有 `/admin/stop`），且当前会话本身就是 bridge 拉起的命令，
  不能自我重启；下次执行 `npm run restart -- --reason "..."` 生效（旧版本会走脚本侧兜底）。

### P6 落地记录（2026-11-02）

- **为什么做**：以前 `resultText` 是 cline 的原始 stdout/stderr（含 `[thinking]`、ANSI、进度行），
  失败原因靠「stderr 第一行像错误的」。`cline --json` 给出结构化事件后，终稿、错误、用量
  都是字段（完整样本见 [`docs/bridge-notes.md`](bridge-notes.md) §8）。
- **bridge**：`commands.cline.json` 默认开 → `runCline()` 传 `--json`；新增
  `src/cline-json.js` 增量解析（chunk 任意位置截断也能拼），`resultText` 取
  `run_result.text`（兜底 `agent_event.done.text`），`errorText` 优先事件里的 error；
  `isClineJsonFailure()` 让「error 事件 + exit 0」也判 `failed`。
  `command finished` 日志补 `finishReason / taskId / toolCalls / outputTokens / cost`。
- **关键事实**：`hook_event.agent_start.taskId` 是 `conv_…`，**不是**会话 ID；
  它与本次新建的 `sessions/<id>` 时间戳不同、`sessions.db.conversation_id` 为 `null`。
  所以命令 → 会话仍靠「快照 + 新增目录 + cwd 比对」（ADR-25），P7 的串行也依赖它。
- **回退**：`bridge/config.json` 里设 `commands.cline.json=false`，回到原来的纯文本输出。
- **验证**：`cd bridge; node --test` 37 项全绿，其中
  `test/cline-json.test.js` 9 项（成功流 / 认证失败 / 任意切块 / 末尾无换行 / 噪声行 /
  终稿优先级 / 截断 / 非 JSON 回退）、`test/command-json-mode.test.js` 3 项
  （假 CLI 端到端：断言 `--json` 被传、`done` 的 `resultText` 是 `OK` 而非 JSON 原文、
  error 事件判 failed、`json=false` 退回原始输出）。
- **待生效**：线上 bridge 还是 12:27 启动的版本，下次重启（建议用 P18 的
  `--when-idle`）后才真正走 `--json`。

### P18 落地记录（2026-11-02）

- **背景**：12:24 在命令里 `restart --keep-session`，bridge 一死 cline 的 stdout 管道就断，
  会话 19 秒后 exit 1（详见 `docs/interruptions.md`）。
- **实现**：`bridge/src/idle-restart.js`（`liveCommandEntries()` 只认 pid + 启动时间都对的；
  `waitForIdle()` 注入 readEntries / inspectProcesses / sleep；锁文件读写 + 存活判断）+
  `bridge/scripts/restart-when-idle.mjs`（detached supervisor，空闲后再 3 秒缓冲、超时不动
  bridge）+ `stop.mjs --when-idle` 入口 + `npm run restart:idle`。
- **验证**：`cd bridge; node --test` 44 项全绿（P18 新增 7 项）；本机实测
  `npm run restart:idle -- --reason "P18 排队验证"` → 日志 `still busy {"commands":["cmd_c2e5d2d05eec"]}`
  → 超时分支 `timeout, bridge left untouched`，bridge pid 未变、锁文件自动清理。
- **边界**：不是热升级，空闲到新命令之间有几秒空窗；只保证不掐断已在跑的命令。
- **待办**：下次真正重启 bridge（例如加载 P6 `--json`）时用
  `cd bridge; npm run restart:idle -- --reason "加载 P6 --json"`。

### 上线状态（2026-11-02 10:55 已全部完成）

1. ✅ 迁移 `004_message_truncated` / `005_message_options` 已应用（`docker compose run --rm hub node src/migrate.js`）
2. ✅ Hub 已重建镜像并重启（新容器 `cline-hub`，`/api/v1/app/latest` 生效）
3. ✅ bridge 已重启并**重置过一次水位**（因为首次回填发生在迁移之前，>8000 字的消息被旧服务端截过），现在按 20000 字重发
4. ✅ App `1.1.0+2` 已打包并 `adb install -r` 到手机（settings/token 保留）
5. ✅ APK 已发布：`/var/www/cline-hub/app/cline-console-1.1.0.apk`，`https://hub.littlewish.top:8443/app/...` 返回 **200 / application/vnd.android.package-archive / 53109532 字节**
6. ✅ Caddy 增加 `handle_path /app/*` 静态出口，`caddy validate` 通过后 `reload`

### 1.1.1 发布记录（2026-11-02 11:15）

1. ✅ Hub 镜像重建并重启：`server/src/text.js` 新增、`sessions.js` 改用它（容器 `cline-hub` 已 Up，`/api/v1/health` 200）
2. ✅ 线上实测：`GET /api/v1/sessions` 的 `resultPreview` 已无 `##` / 代码围栏（例如 `1793582122106_0c056` 从「## 对，「有私钥」——」变成「对，「有私钥」——」）
3. ✅ APK `1.1.1+3` 打包（53,109,532 B，sha256 `4abd0df3…c416`），已放 `/var/www/cline-hub/app/`，HEAD 200 / `application/vnd.android.package-archive`
4. ✅ 清单 `/srv/cline-hub/releases/latest.json` 已更新，`GET /api/v1/app/latest` 返回 1.1.1 / build 3 / 两条 notes
5. ⏳ 手机：当时 `adb devices` 没有设备，未覆盖安装；App 里「设置 → 检查更新」可直接下载安装

### 1.1.2 发布记录（2026-11-02 12:06）

1. ✅ APK `1.1.2+4` 打包成功（**本机已能出包**：`$env:JAVA_HOME='<JDK 17 路径>'`；53,585,288 B，sha256 `93c75ea8…88f0`），Kotlin 原生通知代码编译通过
2. ✅ 已放 `/var/www/cline-hub/app/cline-console-1.1.2.apk`（caddy:caddy 644），线上 HEAD **200 / application/vnd.android.package-archive / 53585288**
3. ✅ 清单 `/srv/cline-hub/releases/latest.json` 已更新，`GET /api/v1/app/latest` 返回 1.1.2 / build 4 / 四条 notes
4. ⏳ 手机：`adb devices` 仍为空，未覆盖安装；App「设置 → 检查更新」直接下载安装（同签名）
5. ⏳ **bridge 需要下次重启才加载对账逻辑**：启动即会跑一遍 `reconcile()`。注意重启会中断当前 in-flight 会话命令（这正是要回收的场景），所以本轮没有强制重启

**已知边界**：回填只覆盖最近 60 个会话（`TRANSCRIPT_BACKFILL_LIMIT`）。
更早的会话（例如 `1791744249853_in12x`，含 33,547 字的长回复）仍是被截断的历史版本；
单独补法：`cd bridge && node scripts/resend-session.mjs <sessionId>`（已用它补过这个会话，
重发后最大单条 20,015 字、`truncated=true`）。

规则：**P3 方案已定为 B** —— 提升限额后，只回填最近 60 个会话（`TRANSCRIPT_BACKFILL_LIMIT`），每 tick 2 个，按字节切批。

### P7 + P14 + P8 落地记录（2026-11-02）

- **P7 并发池**：`tick()` 改为「领取 → 入队」，新增 `pump()` 按 `commands.concurrency`
  （1–8，默认 1）派发；`slots` 记录已派发未 spawn 的命令，同一个 workspace（解析后小写路径）
  强制串行。槽位满时不再领取，避免把 Hub 上的 `pending` 白白改成 `delivered`。
  `shutdown()` 一并把队列里的命令回写 `failed`。ADR-41。
- **P14 取消**：迁移 `007_command_cancel.sql`（`cancel_requested_at` + 活跃状态部分索引）
  与 `008_command_cancelling_status.sql`（**扩 001 的 check 约束**——第一次线上实测直接
  500：`violates check constraint "commands_status_check"`，因为约束里没有 `cancelling`）。
  Hub 新增 `POST /api/v1/commands/:id/cancel`（排队中 → `cancelled`；执行中 → `cancelling`；
  已结束 → 409），PATCH 加了防回翻规则。bridge 每 tick 在槽位检查**之前**查一次
  `status=cancelling`，只杀自己 `children` 里的 commandId；`handle()` 开头做一次预检，
  排队中被取消的命令不会 spawn；`reconcile()` 负责收尾「取消后 bridge 重启」的残留。
  App 命令详情新增「取消这条命令」（二次确认），状态多一档「取消中」。ADR-40。
- **P8 Markdown**：新增依赖 `flutter_markdown_plus`；`MessageText` / `TextViewerPage`
  加 `markdown` 开关，只对会话正文 / 问题 / 会话结果开启，命令输出仍是终端原文。
  长文本折叠态保持纯文本预览，展开页才渲染（`MarkdownBody` 不支持 `maxLines`）。ADR-42。
- **验证**：`cd bridge; node --test` **48 项全绿**（新增 `command-pool.test.js` 2 项、
  `command-cancel.test.js` 2 项，都是真跑 PowerShell 进程的端到端）；`cd server; node --test`
  **18 项全绿**（新增 5 项取消 / 防回翻）；`cd app; flutter analyze` 无问题、
  `flutter test` **56 项通过（5 项真机用例跳过）**。
- **上线**：Hub 镜像已重建，迁移 007 / 008 已应用；线上 `POST /cancel` 对已结束命令返回
  **409**，`cancelling` 在事务内写入再回滚验证通过；APK `1.1.4+6`（55,207,088 B，
  sha256 `60fb0102…2304`）已发布，`HEAD /app/cline-console-1.1.4.apk` 200，
  `GET /api/v1/app/latest` 返回 1.1.4 / build 6。
- **教训**：不要用「最近一条命令」去测取消接口——最新那条很可能就是**当前会话自己**
  （本次真把 `cmd_4699c43ec58a` 置成了 `cancelling`，靠 5 秒内直接改库回滚才没被杀）。
  测试请挑一条 `done` 的命令，或用事务 + `rollback`。
- **待生效**：bridge 需要重启才加载并发池 / 取消轮询（本轮用 `restart:idle` 排了 detached
  supervisor，见 `docs/interruptions.md`）；手机需要装 `1.1.4+6`（`adb devices` 为空，
  走 App 内「检查更新」）。

## 1. 基线快照（2026-11-02 09:15 实测；13:06 更新发布项）

| 项 | 实测 |
|---|---|
| 分支 / HEAD | `master` @ `919ef39`（P7 / P14 / P8） |
| Hub | `{"ok":true,...,"db":{"ok":true,"latencyMs":0},"sseClients":1}` |
| bridge | `{"ok":true,"service":"cline-bridge"}`（手动启动，未开机自启） |
| 线上入口 | `https://hub.littlewish.top:8443` |
| Cline CLI | `3.0.74`（已是最新，`--json` 可用，**没有 `--act`**） |
| Flutter / Dart | `3.47.5` / `13.4` |
| Android 工具链 | SDK `%LOCALAPPDATA%\Android\Sdk`（platforms 33–37 / build-tools 30–37）；JDK 17 与 21 在 `<JDK 目录>\`；`GRADLE_USER_HOME=%USERPROFILE%\.gradle` 已缓存 gradle-9.3.1。**`JAVA_HOME` 为空**，默认 PATH 上是 zulu-8，打包前必须设成 JDK 17 |
| 已跟踪会话 | 89 个（80 个有 `messages.json`），14,755 条已上报消息 |
| App 发布版本 | `1.1.4+6`（`GET /api/v1/app/latest` 实测；APK 55,207,088 B，sha256 `60fb0102…2304`） |

## 2. 里程碑与最近提交

| 里程碑 | 内容 |
|---|---|
| M1 / M2a | Hub 上云 + bridge 远程命令 |
| M2b | Flutter 客户端（会话 / 命令 / 动态 + SSE） |
| M2c | 逐条消息流 + 项目聚合 + 详情页 |
| M3（进行中） | 稳定性与可读性：模式、配色、全文、复制、并发 |

最近 6 个提交：`a20abe1` 无空格 prompt 被当子命令 → `e0995aa` 详情页概览弹层 → `30b51ab` 活动流误报失败 → `161919e` 轮询定时器泄漏 → `d254f49` 回写新会话 ID → `f0e6e69` 会话按项目聚合。

## 3. 拓扑与端口

```
手机 App ──HTTPS:8443──> Caddy ──> Hub 127.0.0.1:3100 ──> Postgres
   ▲                                  ▲
   └────── SSE /api/v1/events ────────┘
Windows bridge ──轮询/上报──> https://hub.littlewish.top:8443
  ├─ 127.0.0.1:3210  收 Cline hook
  ├─ 读 ~/.cline/data/db/sessions.db（只读）
  └─ 执行 cline CLI（无头）
```

| 端口 | 归属 |
|---|---|
| 3210 | bridge hook server（127.0.0.1） |
| 3100 | Hub（127.0.0.1，Caddy 反代） |
| 8443 | HTTPS 入口（备案期临时） |

## 4. 待办（按优先级）

**P0**：备案通过后切回 443 并轮换 token；证书 2027-01-29 前必须改 DNS-01。
**P1**：P11 → P12 → P13 → P6 → P18 → P7 → P14 → P8 都已完成（P7/P14 待 bridge 重启生效）；
下一步候选：真机核对 P2、Web 预览降级（P2 段）、多设备推送。
**P7 用法**：想并行就把 `bridge/config.json` 的 `commands.concurrency` 设成 2+（上限 8），
同一个 workspace 仍强制串行（ADR-41）。
**P2**：App 无 SSE 的 Web 预览降级体验。
**P3**：多设备推送、审计视图细化。

## 5. 已知坑（别重复踩）

1. **CLI 没有 `--act`**：`modeExplicitlySet` 只认 `--plan/--yolo/--zen`，否则模式取 `settings/global-settings.json` 的 `planActMode` → 手机发 act 也会跑成 plan。修法见 `command-worker.js` 的 `clineModeEnv()`。
2. **`--id` 续会话要 TTY**：无头只能 `-c <workspace>` 新开会话。
3. **`spawn` 必须 `stdio: 'ignore'`**：否则 cline 等 stdin，命令永远「执行中」。
4. **prompt 单个词会被当子命令**：不带空格时补尾随空格（`a20abe1`）。
5. **SSE 反代必须 `flush_interval -1`**，否则事件被 Caddy 缓冲。
6. **本机打包要先设 `JAVA_HOME`**：SDK 在 `%LOCALAPPDATA%\Android\Sdk`、JDK 17 在 `<JDK 17 路径>`，
   但默认 PATH 上是 zulu-8（Gradle 9 直接拒绝）。`flutter build apk` 前：
   `$env:JAVA_HOME='<JDK 17 路径>'`（想一劳永逸就 `setx`）。
   `release` 用的是 debug 签名（模板默认），换机器重建会签名冲突、必须先卸载。
7. **会话消息在源头被截断**：`extract.js` 的 `clip()`（`maxTextChars`）与 `maxResultChars`，不是 UI 折叠问题。
8. **`TRANSCRIPT_VERSION` 提升只影响被扫描到的会话**：静止老会话不会自动重发，需重开回填队列（§0 P3）。
9. **发布清单在 `/srv/cline-hub/releases/latest.json`**（docker-compose 只读挂到容器 `/app/releases`），
   不是脚本旧版提示的 `/opt/cline-hub/...`；Hub 每次请求现读，**不用重启**（`systemctl restart cline-hub` 也没有这个 unit）。
10. **`Start-Process -ArgumentList` 不给带空格的参数加引号**：用数组传 `--notes "a b"` 时
    node 只收到第一个词（本次 `latest.json` 的 notes 就被截成「修复：会话列表预览显示成」）。
    直接 `& node ...` 调用，或自己把参数连同引号拼成一个字符串。
11. **PID 会复用**：手机/DB 里只有一个 `pid` 时**不要**直接 `taskkill /pid`。
    bridge 的登记文件里才有 `pidStartedAt`，用 `cd bridge; npm run ps` 双校验；
    要杀就 `npm run ps -- --kill <commandId>`。bridge 崩溃留下的登记用 `--clean` 收。
12. **bridge 重启会把 in-flight 命令变成孤儿**：会话侧会自己翻 `failed`，命令状态只有 bridge 会写，
    不回收就永远「执行中」。现在 `command-worker.reconcile()` 启动时 + 每 60 秒对账一次，
    手动排障用 `cd bridge; npm run reconcile -- --dry-run`（只改状态，不杀进程）。
    **主动重启**请用 `npm run stop` / `npm run restart`（先回写命令，再杀进程树）：
    `Stop-Process` 是硬杀，Node 收不到 `SIGTERM`，`shutdown()` 不执行（ADR-36）。
13. **系统通知只在 App 进程活着时可靠**：退到后台会断 SSE 省电，这期间靠 ntfy；
    回前台会补拉并补发「后台期间结束的命令」。别把它当推送（真要后台推送得上 FCM / 常驻连接）。
14. **`restart:idle` 的默认 3 秒缓冲偏紧**：登记文件在 cline 子进程 `close` 时就删，
    回写 `done` 的 PATCH 在之后才发，`shutdown()` 可能把正在收尾的命令判成 in-flight
    并改成 `failed`。在命令里发起重启时加上 `--grace 15000`
    （`cd bridge; npm run restart:idle -- --reason "..." --grace 15000`）。

## 6. 自检命令

```powershell
cd bridge; node --test; node scripts/check-workspace-whitelist.mjs
cd server; npm test; npm run migrate
cd app;    flutter pub get; flutter analyze; flutter test
node site/check-site.mjs
powershell -NoProfile -File deploy/windows/verify-hub.ps1
```

## 7. 文档一致性

- 改行为 → 同步模块 README + 根 README 对应段落。
- 新的「为什么」→ `docs/decisions.md` 追加 ADR（编号递增，不改旧条目）。
- 现状变化 → 本文件 §1 + §8。
- 接口变化 → `docs/api.md` 先改契约再写码。

## 8. 变更日志

| 日期 | 变更 |
|---|---|
| 2026-11-02 | 新建 `docs/status.md` / `docs/README.md`，README 加「文档」入口 |
| 2026-11-02 | P1：bridge 注入 `CLINE_GLOBAL_SETTINGS_PATH` 钉死模式；跑完核对 `metadata.mode` 并写警告；详情页模式栏继承最近一条命令 |
| 2026-11-02 | P2：新增 `kPlan`/`kAct` 与 `modeSegmentStyle()`，修复 PLAN/ACT 选中态低对比；命令卡片模式 Pill 按模式着色 |
| 2026-11-02 | P3：消息上限 2000→20000、结果 4000→12000；`clip()` 返回 `truncated`；`TRANSCRIPT_VERSION=2` + 回填重新排队 + 按字节切批；migration 004 |
| 2026-11-02 | P4：消息气泡复制、AppBar「复制整段对话」、长文本折叠 + `TextViewerPage` 全文页 |
| 2026-11-02 | P9：`ask_question` → `kind=question` + `options jsonb`（migration 005）；App 渲染成按钮，点选变新命令 |
| 2026-11-02 | P10：版本 1.0.0+1 → 1.1.0+2；设置页「版本与更新」+ 更新日志 + 检查更新；`GET /api/v1/app/latest`；`app/scripts/release-apk.mjs` |
| 2026-11-02 | P3/P9/P10 **已上线**：迁移 004/005 应用、Hub 镜像重建并重启、Caddy 增加 `/app/*` 静态出口、APK 发布（HTTP 200 / 53,109,532 B）、手机装 1.1.0(2)；bridge 重置水位后按 20000 字重发 |
| 2026-11-02 | P5：新增 `server/src/text.js`（`stripAnsi` / `stripMarkdown` / `plainPreview`）；列表与详情先取 `result_text` 前 2000 字、服务端洗成 400 字纯文本（SSE 200 字）；`server/test/text.test.mjs` + `npm test`；App 新增 `stripAnsi` / `inlinePreview`，命令卡片与命令详情按纯文本展示/复制 |
| 2026-11-02 | P5 **已上线**：Hub 镜像重建 + 重启，线上 `resultPreview` 实测无 Markdown/ANSI；App `1.1.1+3` 打包并发布（APK + `/srv/cline-hub/releases/latest.json`），`/api/v1/app/latest` 返回 1.1.1；`release-apk.mjs` 的清单路径与重启提示改正 |
| 2026-11-02 | **开发计划重排**：先「看得见、杀得准」再并发 —— P11（Step 1 进程身份）→ P12（Step 2 本机登记）→ P13（卡死回收）→ P6（`--json`）→ P7（并发池）→ P14（手机取消）→ P8（Markdown）→ P2（真机核对） |
| 2026-11-02 | **P11（Step 1）**：migration `006_command_process.sql` 加 `pid` / `pid_started_at` / `runner`；bridge spawn 成功立刻 PATCH 回写；`toCommand()` 输出三字段；App `CommandItem` 增加 `pid` / `pidStartedAt` / `runner`，详情页显示 `pid · runner · 启动于` 并提供「复制排查命令」 |
| 2026-11-02 | **P12（Step 2）**：`bridge/src/command-registry.js` 落 `%TEMP%\cline-hub-cmd\running\<commandId>.json`；`npm run ps`（表格 / `--json` / `--kill <id>` / `--clean`）用「pid + 启动时间」双校验；`stop()` 从单槽位改为杀掉全部已登记子进程 |
| 2026-11-02 | **P13**：`command-worker.reconcile()`（启动 + 每 60s）把「Hub 上 running、本机已无进程」的命令回写 `failed` 并说明原因，不杀进程；`classifyRunningCommand()` / `processLiveness()` 纯函数 + 15 项 bridge 测试；新增 `src/process-info.js`（与 `npm run ps` 共用）与 `npm run reconcile [-- --dry-run]`；实测清掉卡了 19 分钟的 `cmd_3ced4a851f4c` |
| 2026-11-02 | **P15**：手机端系统通知（命令完成/失败 + 会话终态）——原生 `MethodChannel`（`MainActivity` + `ic_stat_hub` + `POST_NOTIFICATIONS`）、`HubNotifier` 抽象、设置页两个开关与「请求权限」、后台期间结束的命令回前台补发；App `1.1.2+4`；ADR-34/35 |
| 2026-11-02 | **1.1.2 已发布**：APK 53,585,288 B / sha256 `93c75ea8…88f0` 放到 `/var/www/cline-hub/app/`，清单更新，`GET /api/v1/app/latest` 返回 1.1.2；手机未连 adb，走 App 内「检查更新」安装；bridge 对账逻辑待下次重启生效 |
| 2026-11-02 | **P16 优雅停止**：`POST /admin/stop` + `commandWorker.shutdown()`（先回写执行中的命令为 failed，再杀进程树）+ `npm run stop` / `npm run restart` + `docs/interruptions.md`（主动中断记录）+ ADR-36 |
| 2026-11-02 | **P17 打开下载页**：`link_launcher.dart` + `MainActivity` 的 `openUrl`（ACTION_VIEW），设置页新版本卡片改成「打开下载页」+「复制链接」；App `1.1.3+5`；ADR-37 |
| 2026-11-02 | **P11/P12/P13/P16 已上线**：Hub 迁移 006 已应用（线上 `GET /commands` 返回 `pid/pidStartedAt/runner`）；bridge 12:27 重启后加载本机登记、启动对账与 `/admin/stop`（重启记录见 `docs/interruptions.md`） |
| 2026-11-02 | **P6**：bridge 默认给 cline 加 `--json`，新增 `src/cline-json.js` 增量解析（终稿 / finishReason / error / usage / taskId）+ `isClineJsonFailure()`；`resultText` 取 `run_result.text`，失败原因优先事件 error；`commands.cline.json=false` 可回退；9 个单元 + 3 个假 CLI 端到端用例，bridge 37 项全绿；ADR-38；`docs/bridge-notes.md` §8 记实测事件样本 |
| 2026-11-02 | **P18**：`npm run restart:idle`（= `stop.mjs --restart --when-idle`）拉起 detached supervisor，等执行中的命令跑完 + 3 秒缓冲后再重启；`liveCommandEntries()` 只认 pid + 启动时间双校验，超时/查询失败不动 bridge，锁文件防连点；`--keep-session` 注释更正为「保不住会话」。7 项测试，ADR-39；本机排队 / 超时验证通过 |
| 2026-11-02 | **bridge 重启（when-idle）**：用户在手机上下发「重启 bridge」(`cmd_3ac6900fc5c5`) 时，该命令拉起的会话就是当前会话，故用 `npm run restart:idle -- --grace 15000` 排 detached supervisor，等命令跑完 + 15 秒缓冲再走 `/admin/stop` 优雅重启；顺带记下「默认 3s 缓冲偏紧」的坑（§5.14、`docs/interruptions.md` §2 12:51） |

| 2026-11-02 | **P7 并发池**：`tick()` 改成「领取 → 入队」，`pump()` 按 `commands.concurrency`（默认 1、上限 8）派发；`slots` 覆盖「已派发未 spawn」窗口，同一 workspace（解析后小写路径）强制串行；槽位满不领取；`shutdown()` 同时收尾队列；新增 `test/command-pool.test.js` 2 项；ADR-41 |
| 2026-11-02 | **P14 取消命令**：迁移 007（`cancel_requested_at` + 部分索引）/ 008（扩 `commands_status_check`）；`POST /api/v1/commands/:id/cancel`（排队中直接 `cancelled`、执行中 `cancelling`、已结束 409）；PATCH 防回翻；bridge 每 tick 查 `status=cancelling` 并按 commandId 杀、spawn 前预检、reconcile 收尾残留；App 详情页「取消这条命令」；5 项 server + 2 项 bridge 测试；ADR-40 |
| 2026-11-02 | **P8 Markdown**：新增 `flutter_markdown_plus`；`MessageText` / `TextViewerPage` 加 `markdown` 开关（只对会话正文 / 问题 / 结果生效，命令输出保持原文）；折叠态仍纯文本，展开页渲染；`test/markdown_test.dart` 4 项；ADR-42 |
| 2026-11-02 | **Hub 上线**：镜像重建 + 迁移 007/008 应用；线上实测取消已结束命令返回 409、`cancelling` 事务内回滚验证通过；**踩坑**：第一次取消返回 500（`commands_status_check` 不允许 `cancelling`），补 008 解决；另把当前会话命令误置 `cancelling`，5 秒内改库回滚（详见 `docs/interruptions.md`） |
| 2026-11-02 | **1.1.4+6 已发布**：APK 55,207,088 B / sha256 `60fb0102…2304` → `/var/www/cline-hub/app/cline-console-1.1.4.apk`（HEAD 200）、清单 `/srv/cline-hub/releases/latest.json`，`GET /api/v1/app/latest` 返回 1.1.4 / build 6 / 四条 notes；`release-apk.mjs` 新增 `--skip-build`（构建超时后可只补清单）；`adb devices` 为空，手机走 App 内「检查更新」 |

