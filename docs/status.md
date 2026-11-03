# 现状与待办（status）

> 每次开工先读 §0；动手前核对 §1 的实测值。最后更新：**2026-11-04（+08）**。

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
| 10 | P2 | PLAN/ACT 选中态真机核对对比度（需要手机，用户侧） | ✅ 2026-11-03 用户在真机确认两个按钮的对比没问题，不用再调配色 |
| 11 | P16 | 停 bridge 前先停任务：`POST /admin/stop` + `commandWorker.shutdown()`（先回写 running，再杀进程树）+ `npm run stop` / `npm run restart` + `docs/interruptions.md` | ✅ 已上线（bridge 12:27 起为新版本；未在本会话里自杀验证） |
| 12 | P17 | App 自动更新可直接「打开下载页」：原生 `ACTION_VIEW`（`link_launcher.dart` + `MainActivity`），复制链接保留 | ✅ 已发布 `1.1.4+6`（与 P8 一起发版） |
| 13 | P19 | **读接口按设备隔离**：`device` token 只能读自己的会话 / 消息 / 命令 / hook（跨设备 403），SSE 按设备过滤；`app` / `admin` 不传即全量 | ✅ 已上线（2026-11-02 13:28 镜像重建；线上 device 跨设备读返回 `403 device_mismatch`） |
| 14 | P20 | **路径归一化上线**：`normalizeFsPath()`（写入 + 读取）重建镜像 | ✅ 已上线（2026-11-02 13:50，备份后缀 `20261102-135023`；线上 106 条会话已无正斜杠 `workspaceRoot`） |
| 15 | P21 | **bridge 手工重发**：`npm run resend`（`--missing-project` / `--session` / `--recent` / `--dry-run` / `--no-messages` / `--device` + `--token`），上报体与正常采集共用 `src/record.js` | ✅ 已可用（bridge 测试 53 项）；6 条旧会话本地已被 Cline 清掉，补不了 |
| 16 | P22 | **命令卡片显示项目目录 + 耗时每秒刷新**：`workspaceLabel()` + `ElapsedText`（MetaLine 新增 `trailing` 槽位） | ✅ 代码 + 测试完成（App 未发版） |
| 17 | P23 | **多设备过滤**：会话 / 命令 / 动态页在 ≥2 台设备时出现设备 chip（`HubStore.deviceFilter` + `visible*`） | ✅ 已发布 `1.1.5+7` |
| 18 | P24 | **设备列表接口**：`GET /api/v1/devices`（app 看全部、device 只看自己；在线时间 / 会话数 / 待执行 / 执行中）+ App 设置页「已接入设备」卡片、chip 用设备名 | ✅ Hub 已上线（2026-11-02 14:07）；App `1.1.5+7` |
| 19 | P25 | **接入文档**：`docs/new-device.md`（第二台电脑）、`docs/self-host.md`（从零自托管 / 多设备 / 多人边界）、`bridge/README.md` | ✅ 已写入仓库 |
| 20 | P26 | **App 1.1.5+7 发版**：设备列表 + 设备名 chip + 命令卡片项目目录 / 实时耗时 | ✅ APK 55,239,940 B / sha256 `53a64cd1…d5ac`，已上线 |
| 21 | P32 | **同一条任务只弹一条通知**：命令终态与 bridge 合成的 `session_done` 用 `sessionId` 归并（15 分钟窗口），修「息屏回前台收到两条消息」 | ✅ 已随 `1.1.6+8` 发版 |
| 22 | P33 | **会话分组显示来源机器**：分组键改成 `<设备>\|<项目键>`（两机的同名项目是两组），组头 + 卡片元信息显示设备名；设备过滤也作用于工作区页 | ✅ 已随 `1.1.6+8` 发版 |
| 23 | P34 | **后台保活（形态 B）**：只在「有命令在跑」时挂 `dataSync` 前台服务（`KeepAliveService` + 静音常驻通知），锁屏期间 SSE 不断、命令跑完立刻弹通知；活跃数归 0 / 401 / 关开关 / 划掉任务即停。设置页「锁屏也提醒」默认开 | ✅ 已发版 `1.1.6+8`（2026-11-03 08:28）；静态 + 自动化验证已完成（见 P37），真机 7 条仍待手机 |
| 24 | P35 | **App 1.1.6+8 发版**：锁屏保活 + 通知归并 + 分组带设备一起上线（清单 `/srv/cline-hub/releases/latest.json`、APK `/app/cline-console-1.1.6.apk`），落地页对齐 1.1.6 | ✅ APK 55,256,496 B / sha256 `4ecaf2f3…4173`，已上线 |
| 25 | P37 | **推送 / 保活验证（不接厂商通道）**：ntfy 直达通知栏 + Hub SSE 长连接 + 线上 1.1.6 APK 静态核验（保活 service / 权限 / sha256）+ 全量自检；真机 7 条仍需手机 | ✅ 2026-11-03 完成「不依赖真机」的全部验证（ADR-51） |
| 26 | P38 | **右侧划出菜单 + 发送文件 / 图片**：设备列表与设置入口挪进 `endDrawer`；`POST/GET /api/v1/attachments`（base64 + bytea，migration 009）+ 命令携带 `attachmentId`；bridge 落盘到 `%TEMP%\cline-hub-cmd\incoming` 再把绝对路径拼进 prompt；下发面板与会话输入框都能「选文件 + 写一句要它做什么」 | ✅ **已上线（2026-11-03 12:25）**：迁移 009 + 镜像重建（备份 `server.bak-20261103-122537`），线上 app token 上传 / 下载实测通过；附件带**入库时间 `createdAt`**（保留策略暂不做）；App `1.1.7+9` 已发布（55,568,256 B / sha256 `4261c8f2…ee25`）；bridge 已排空闲重启（等 `cmd_10e3f1f2394f` / `cmd_b4c3e28a6d9b` 两条在跑的命令都结束，supervisor pid 3260） |
| 27 | P39 | **浏览入口收进右侧抽屉 + 设置页去重**：会话页「按工作区浏览」按钮与三页顶部的设备 chip 挪进 `HomeDrawer`「浏览」区（`onOpenWorkspaces` 回调由 `HomeShell` 提供）；页面只在筛选生效时显示 `ActiveDeviceFilterBar`（「只看 X」+「看全部设备」）；抽屉设备行离线时补「多久没上报」；设置页删掉重复的「已接入设备」卡片，手填默认设备改名「手填兜底」 | ✅ 已发版 `1.1.8+10`（ADR-54） |
| 28 | — | **安全审计复核**：把手机发来的 `cline-hub 安全审计与加固建议.docx` 逐条对代码核了一遍（说对的 7 条 / 说错或夸大 4 条 / 漏掉 4 条 / 实测 4 项），结论与采纳计划写进 [`security-review.md`](security-review.md) | ✅ 文档完成（ADR-55；**未改任何行为代码**） |
| 29 | P40 | `net.js` 取 `X-Forwarded-For` **最后一段** + `deploy/Caddyfile` 显式 `header_up`，补 `server/test/net.test.mjs` | ⏳ 未开工（等用户拍板；复核文档 §5） |
| 30 | P41 | SSE 短期 ticket（`POST /api/v1/sse-ticket`）替代 URL 里的 token，App 跟着改 | ⏳ 未开工（含 App 发版） |
| 31 | P42 | 命令租约自动回收（`migrations/010` + 每 60s 扫描 → `failed: orphaned`） | ✅ 已实施（见 P47；`reconcile` 保留为手动兜底） |
| 32 | P43 | SSE 纵深防御：Origin 白名单 + 单 token 连接上限 + 空闲超时 | ⏳ 未开工 |
| 33 | P44 | **App 实时看 DeepSeek 余额**：Hub 新增 `GET /api/v1/deepseek/balance`（Key 只读 `server/.env` 的 `DEEPSEEK_API_KEY`；60 秒缓存、并发复用、失败退旧值并标 `stale`）；App 右侧抽屉顶部「DeepSeek 余额」卡片（总额 / 充值 / 赠金 / 更新时间 + 可用标记），启动、回前台、打开菜单、命令走到终态时自动刷新，右上角可强制刷新 | ✅ **已上线（2026-11-03 19:47）**：服务器 `.env` 写入 `DEEPSEEK_API_KEY` + 镜像重建（备份 `20261103-194741`，23 条路由）；App `1.1.9+11` 已发版（ADR-56） |
| 34 | P45 | **品牌统一为 ClineHub（A 层）+ App 1.2.0+12 发版**：展示文案全部改成 ClineHub（ADR-57 / ADR-58），包名 / applicationId / 库名 / 目录 / 环境变量 / APK 文件名一律不动；版本号 1.1.9+11 → **1.2.0+12**，落地页六处版本引用同步 | ✅ **已上线（2026-11-04 04:30）**：提交 `63488a9`；APK 55,601,132 B / sha256 `fb543395…8901` / `versionCode=12` / `aapt2` label `ClineHub`，已发 `/app/cline-console-1.2.0.apk` + `latest.json`；站点已更新（IP 站 200 / 19,392 B） |
| 35 | P46 | **微信式输入条**：新建 `ui/chat_composer.dart`（左侧「+」就地展开「图片 / 文件」、圆角输入框、右侧发送；附件缩略图 / 名字 · 大小可移除；空内容发送键禁用）；会话详情与下发面板共用，`attachment_bar.dart` 只留选文件与文案 | ✅ 代码 + 测试完成（`flutter test` 101 通过 / 5 跳过；ADR-59；随 1.3.0+13 发版） |
| 36 | P47 | **命令租约（P42 落地）**：migration 010 `lease_expires_at` + `POST /api/v1/commands/:id/heartbeat` + Hub 每 60s 扫过期（delivered/running → failed，cancelling → cancelled，广播 `command.update`）+ 终态不接受 `running`；bridge 每 30s 续租（含排队中的命令） | ✅ **Hub 已上线（2026-11-04 06:31）**：备份 `server.bak-20261104-063124`、`routes: 24`、线上心跳实测 200、过期自检行 22:33:02 被扫成 `failed`；bridge 已排空闲重启（supervisor pid 6376）。验证 server **65** / bridge **61** |




已完成并上线的：P0 / P1 / P3–P26 / P35–P45 / P46 / P47
（P3、P9 已部署；P5、P10、P15、P17、P8、P22–P26、P35、P38、P46 已发布到 App；
P7/P14 已重启生效；P47 的 Hub 侧已上线，bridge 侧等空闲重启）。
**P39 已随 `1.1.8+10` 发版**（浏览入口收进右侧抽屉 + 设置页去重，ADR-54；
`flutter analyze` 无告警、`flutter test` **88 通过 / 5 跳过**；APK 55,568,256 B /
sha256 `a17a2ca0…a314`，线上 HEAD 200、`GET /api/v1/app/latest` 返回 1.1.8 / build 10）。
**P44（DeepSeek 余额）已上线（2026-11-03 19:47）**：Hub 代查 `api.deepseek.com/user/balance`，
Key 只存在服务器 `/srv/cline-hub/server/.env`（`600`；App 与日志都看不到，响应体实测无 token）；
线上 `GET /api/v1/deepseek/balance` 返回 `configured:true` / `CNY 14.37` / `isAvailable:true`，
第二次请求 `cached:true`、`?refresh=1` 重新打上游（84ms）。
验证：`cd server; node --test` **56 通过**、`cd app; flutter analyze` 无告警 +
`flutter test` **97 通过 / 5 跳过**（新增 3 条模型 + 4 条 store + 2 条抽屉用例）。
App 发版 `1.1.9+11`（右侧抽屉顶部卡片），装到手机即可看到（ADR-56）。
**安全审计复核（2026-11-03）已完成文档部分**：`cline-hub 安全审计与加固建议.docx` 的
7 条说对、4 条说错/夸大（SSE 心跳其实有、CVE-2026-59723 实为 8.8/AV:A 且本机 `cline 3.0.74` 已修、
XFF 是「取段错」不是「条件错」、Origin 该降级）、4 条它漏掉（其中 SSE token 在 URL 里最该修）。
采纳计划 P40–P43 已登记，**按用户拍板只写文档、不动行为代码**（ADR-55，见 [`security-review.md`](security-review.md)）。

**P32 / P33 / P34 已随 `1.1.6+8` 发版**（`flutter test` 78 通过 / 5 真机用例跳过；
APK 55,256,496 B / sha256 `4ecaf2f3…4173`，线上 APK HEAD 200、`GET /api/v1/app/latest` 返回 1.1.6 / build 8）。
P34 仍需真机按 §0 的清单核对（锁屏收通知 / 常驻通知消失 / 划掉任务）。
**P36 / P37（2026-11-03）已完成并提交**（`c9de875`）：根 README 改成使用者视角（423 → 200 行）；
推送 / 保活把「不依赖真机」的部分全验证了一遍 —— ntfy 发布 **HTTP 200**（`id=dlyLaLiL8GFm`，0.76s）、
app token 连 `GET /api/v1/events` 27 秒收到 `: connected` + 2 条 `event: messages` + 一次 `: ping`
（反代没缓冲）、线上 APK 里的 `KeepAliveService` 与三个权限都在。
用户同时拍板：**不接 FCM / 厂商推送**（ADR-51）。P2 也由用户在真机确认「两个按钮的对比没问题」后关闭。
**P19（读接口按设备隔离）已上线**（2026-11-02 13:28 镜像重建，迁移无变化）。
**P20（路径归一化）已上线**（2026-11-02 13:50 镜像重建，备份后缀 `20261102-135023`）。
**P21–P26 已上线/已发版**：重发脚本 / 命令卡片项目目录 + 动态耗时 / 多设备过滤 / 设备列表接口 /
接入文档；App `1.1.5+7`（`flutter test` 67 项通过，5 项真机用例跳过）。

### P32 + P33 落地记录（2026-11-02）

- **P32 为什么**：用户在息屏 → 回前台时收到同一任务的两条通知。一次远程命令会写两次终态：
  bridge 立刻 PATCH 的 `command.update`，和 30 秒「终态稳定」后合成的 `session_done`
  （会话就是这条命令开出来的）。`HubStore` 原来的去重键是 `cmd_x:done` / `hook:185`，
  两者互不相识，所以先弹「命令完成 · ACT」、再弹「会话完成 · cline-hub」；
  息屏期间 SSE 断了，回前台先补发命令、随后 hook 事件到达时又弹一次，最容易被看到。
- **P32 改法**：新增 `_notifiedTasks`（`sessionId → 首次提醒时间`，窗口 15 分钟）。
  命令 / 会话两个通知出口在弹之前都查它、弹之后写入；先到哪条弹哪条，另一条静默。
  没有 `sessionId` 的老数据（命令没回写、Cline 自己的会话）行为不变。
- **P33 为什么**：工作区分组键只有项目路径，两台电脑上的同名项目会被并成一组，
  组头的「N 条」混着两台机器；而且组头没有来源机器标识，看不出差别。
- **P33 改法**：`_groupKey()` 前缀 `<deviceId>|`，`SessionGroup` 新增 `deviceId` / `loose`；
  组头右侧加设备 Pill（`HubStore.deviceLabel()`，没有名字时退回 id），组内卡片元信息补
  `设备 …`；`sessionGroups` 也走设备过滤（工作区页同样受 chip 影响）；
  `loose` 取代原来对 `key == '__loose__'` 的字符串比较。
- **验证**：`cd app; flutter analyze`（No issues，20.6s）、`flutter test` **71 通过 / 5 跳过**
  （新增 3 条通知归并用例 + 1 条多设备分组用例 + 组头设备名断言）。

### P34 真机验证清单（待做，装 `1.1.6+8` 后逐条核对）

| # | 操作 | 期望 |
|---|---|---|
| 1 | 手机下发 `act` 命令 → 立刻息屏 | 命令结束时**锁屏收到本地通知**；期间通知栏有「ClineHub · 有 1 条命令正在执行」常驻通知 |
| 2 | 同上，同时看着 ntfy | 确认是否**双响**；双响就记成已知边界（两条通道独立，见 ADR-50），或让用户关掉设置里「会话完成 / 失败」 |
| 3 | 命令跑到终态 | 常驻通知**自动消失**，普通完成通知仍在 |
| 4 | 系统设置里撤销 `POST_NOTIFICATIONS` → 再下发命令 | 服务不崩、不弹通知，命令照常执行；回前台仍能看到结果 |
| 5 | 命令运行期间从最近任务划掉 App | 常驻通知消失（`stopWithTask="true"`），bridge 侧命令继续执行 |
| 6 | Android 15+ 跑一条正常命令 | `onTimeout` 不触发（`dataSync` 6h/24h 上限与分钟级命令无关） |
| 7 | 国产 ROM（MIUI / EMUI 等）仍被冻结 | 设置里给 App「电池优化 → 无限制」后重试；仍不行就关「锁屏也提醒」（回退到回前台补发），并记进 `app/README.md` 排障 |

### P37 推送 / 保活验证记录（2026-11-03）

**背景**：本机 `adb devices` 为空（adb 用的是本机 Android SDK 的 platform-tools，但没有设备在线），
P34 的 7 条真机项这一轮做不了。所以把「不依赖手机就能验证的部分」全部做掉，
剩下的明确留给用户。用户同时拍板：**不接 FCM / 厂商推送通道**（ADR-51）。

| # | 验证项 | 做法 | 结果 |
|---|---|---|---|
| 1 | ntfy 推送通道 | `POST https://ntfy.sh` 的 `~/.cline/notify.config.json` topic，body 与 `hooks/_notify.ps1` 完全一致 | ✅ **HTTP 200**，`id=dlyLaLiL8GFm`，0.76s（手机装了 ntfy 并订阅该 topic 即进通知栏） |
| 2 | app token 有效性 | `GET /api/v1/sessions?limit=1` + `Authorization: Bearer` | ✅ 200 / 992 B |
| 3 | Hub SSE 长连接 | `curl -N -m 27 "https://hub.littlewish.top:8443/api/v1/events?token=<app token>"` | ✅ `: connected` → 2 条 `event: messages` → `: ping`，说明鉴权、设备过滤、Caddy `flush_interval -1` 都正常（ADR-5） |
| 4 | 线上 APK 是带保活的那个 | `Get-FileHash` + `aapt2 dump badging` / `dump xmltree` | ✅ sha256 `4ecaf2f3…4173` / 55,256,496 B，与线上 `Content-Length` 一致；`versionCode=8` / `1.1.6`；`KeepAliveService`（`foregroundServiceType=0x1` dataSync、`stopWithTask=true`）；权限含 `POST_NOTIFICATIONS` / `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_DATA_SYNC` |
| 5 | 自动化基线 | bridge / server / app / site | ✅ `node --test` **53**、`npm test` **39**、`flutter analyze` 无告警 + `flutter test` **78 通过 / 5 跳过**、`node site/check-site.mjs` 通过 |
| 6 | 真机 7 条 | 需要手机（锁屏收通知 / 常驻通知消失 / 划掉任务 / 撤权限 / Android 15 / 国产 ROM） | ⏳ 待用户装 `1.1.6` 后按上面的清单逐条核对 |

**复现命令**（token / topic 现读现用，不要写进文档或提交）：

```powershell
# 1) ntfy：和 hooks/_notify.ps1 同一条路径
$cfg = Get-Content "$env:USERPROFILE\.cline\notify.config.json" -Raw | ConvertFrom-Json
$body = @{ topic=$cfg.topic; title='self-test'; message='hi'; priority=3 } | ConvertTo-Json -Compress
$p = "$env:TEMP\ntfy.json"; [IO.File]::WriteAllText($p, $body, (New-Object Text.UTF8Encoding($false)))
curl.exe -sS -m 20 -H 'Content-Type: application/json; charset=utf-8' --data-binary "@$p" $cfg.ntfyBase

# 2) SSE：-m 27 正好覆盖一次 25 秒心跳；只看到 ": connected" 也算连上了
$tok = (Get-Content .secrets\phone-token.txt -Raw).Trim()
curl.exe -sS -N -m 27 "https://hub.littlewish.top:8443/api/v1/events?token=$tok"

# 3) APK 里到底有没有保活（本机 SDK 不在默认位置就换成实际路径）
& "$env:LOCALAPPDATA\Android\Sdk\build-tools\36.1.0\aapt2.exe" dump xmltree `
    --file AndroidManifest.xml app\dist\cline-console-1.1.6.apk |
  Select-String 'KeepAliveService|foregroundServiceType|stopWithTask'
```

**踩到的坑**：PowerShell 5.1 的 `Out-File -Encoding utf8` 会写 BOM，ntfy 直接回
`40024 invalid request: request body must be valid JSON`；换 `UTF8Encoding($false)` 立刻 200。
`hooks/_notify.ps1` 用的是 `Encoding.UTF8.GetBytes()`，不受影响。

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
单独补法：`cd bridge && node scripts/resend.mjs --session <sessionId>`（已用它补过这个会话，
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
  `flutter test` **57 项通过（5 项真机用例跳过）**。
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

### P19 落地记录（2026-11-02）

- **背景**：现在只有一台 Windows bridge，读接口没做设备过滤也没人察觉；一旦接入第二台，
  `device` token 就能读到别的设备的会话、消息、命令和 hook，SSE 也是全量广播。
  「多设备推送」之前先把「串设备」堵住。
- **Hub**：`src/util.js` 新增 `readDeviceScope()`（device 强制自己、跨设备 403
  `device_mismatch`；app/admin 不传即全部），接入 `GET /sessions`、`/sessions/:id`、
  `/sessions/:id/messages`、`GET /commands`、`/commands/:id`、`GET /hooks`；
  `GET /commands/:id` 对 device 读别人的命令返回 403。
  `src/http.js` 新增 `sseMayReceive()`，`broadcast()` 跳过不属于该设备的事件
  （负载没有 `deviceId` 时不发给 device，宁可少推）。
- **兼容性**：bridge 拉 `/commands?deviceId=<自己>`、`/commands/:id`、`/commands/pending`
  全部照旧；App 是 `app` 角色、不带 `deviceId`，仍是全量。单设备下行为零变化。
- **验证**：`cd server; node --test` 30 项全绿（新增 `test/scoping.test.mjs` 12 项：
  会话列表 / 详情 / 消息、命令列表 / 详情、hook、`sseMayReceive`、SSE 广播过滤、
  HTTP 层跨设备 403）。
- **上线（13:28）**：覆盖 5 个源码文件后 `docker compose build` + `up -d`（备份后缀
  `bak-20261102-132824`），health 200；线上实测 app 读 `/sessions`、`/commands`、`/hooks`
  均 200，device 跨设备读三处均为 `403 device_mismatch`，bridge 上报与领取请求继续 200。

### 工作目录去重落地记录（2026-11-02）

- **现象**：工作区页 `cline-hub` 出现两组。线上实测 105 条会话里：
  `...\chat\kids_points_app` 48 条、`...\chat\cline-hub` 31 条、散会话 16 条、
  `...\chat` 5 条、`.../chat/cline-hub`（正斜杠）1 条、`C:\Users\alice` 4 条。
- **原因**：① 项目识别上线前的 6 条旧会话 `project*` 三列为空，App 退回按绝对路径分组；
  ② 其中 `1793525352475_06fzv` 的 `workspace_root` 是 cline CLI 写的正斜杠，
  App 的分组键只 `toLowerCase()`，没归一化分隔符 → 与反斜杠那组不相等（ADR-44）。
- **Hub**：`src/util.js` 新增 `normalizeFsPath()`；`POST /sessions` / `POST /commands` /
  `POST /hooks` 写入前归一化，`toListItem()` / `toCommand()` / hook 列表读取时再归一化，
  历史行不回填也能合并。
- **App**：`HubStore._pathKey()`（分隔符 / 重复斜杠 / 尾斜杠 / 大小写）用于 `sessionGroups`
  的分组键与 `knownWorkspaces` 去重；展示值不变。
- **验证**：`cd server; node --test` 36 项全绿（新增 `test/paths.test.mjs` 6 项）；
  `cd app; flutter test` 58 项通过（新增分组归并用例）。
- **待办**：Hub 需重新部署后线上才生效；那 6 条旧会话的 `project*` 仍是空，
  要显示项目名得让 bridge 重发一次（步骤见 ADR-44；当前有 in-flight 命令，未重启）。

### P20–P23 落地记录（2026-11-02）

- **P20 上线**：只覆盖 `server/src/util.js` + `routes/{sessions,commands,hooks}.js`，
  备份后缀 `20261102-135023`，`docker compose build` + `up -d` 后 health 200。
  线上实测 106 条会话：`workspaceRoot` 含正斜杠的 0 条（部署前有 1 条
  `.../chat/cline-hub`）。
- **P21 重发**：`bridge/src/record.js`（从 `index.js` 抽出 `workspaceName` /
  `sessionState` / `effectiveStatus` / `toRecord` / `fingerprintOf`）+
  `bridge/scripts/resend.mjs`（`npm run resend`，替代只发消息的 `resend-session.mjs`）。
  用法：`--missing-project` / `--session <id>` / `--recent <n>` / `--dry-run` /
  `--no-messages` / `--device` + `--token` / `--data-dir`。
- **实测结论（重要）**：Hub 上 `project` + `projectKind` 都为空的旧会话是 **6 条**，
  但本机 `sessions.db` 里已经**没有**这些行（Cline 清过；97 条本地 vs 106 条线上），
  `messages.json` 目录也不在了 → 重发脚本只能报「跳过」。
  这 6 条的 `project*` 只能靠一次性改库回填，或等它们自然沉到列表底部；**别指望重发**。
  另外 20 条 `project` 为空的会话是 `projectKind=loose`（`...\chat`、家目录），
  本来就没有项目名，不是缺数据。
- **P22/P23 App**：`workspaceLabel()`（路径末段）、`ElapsedText`（执行中每秒重算）、
  `MetaLine.trailing`、`DeviceFilterBar` + `HubStore.deviceFilter` / `visible*`。
  命令卡片元信息 = 「项目目录 · 设备 · 相对时间 · 耗时」，完整路径仍在详情页。
- **验证**：`cd bridge; node --test` 53 项（新增 `test/record.test.mjs` 5 项）、
  `cd server; node --test` 36 项、`cd app; flutter analyze` 无告警、
  `flutter test` 64 项通过（新增 `workspaceLabel` 2 项 + 设备过滤 1 项 + `ElapsedText` 3 项）。

## 1. 基线快照（2026-11-02 09:15 实测；14:08 更新发布项；2026-11-03 复核 Hub / SSE / APK；2026-11-04 06:40 复核 P42 / P46 部署与 1.3.0 发版）
| 项 | 实测 |
|---|---|
| 分支 / HEAD | `master`（P7 / P14 / P8 之后；当前哈希看 `git log -1`） |
| Hub | `{"ok":true,...,"db":{"ok":true,"latencyMs":1},"sseClients":1}`（2026-11-02 14:19 重部署后实测） |
| Hub 部署 | 2026-11-04 06:31 重建（迁移 `010_command_lease` 已应用，`routes: 24`，`command lease 120s / sweep 60s`；备份 `server.bak-20261104-063124`）；上一次是 2026-11-03 12:25（`009_attachments`，`routes: 22`） |
| 设备列表 | 已上线：app / device token `GET /api/v1/devices` 均返回 1 台（`localone` / LocalOne-Windows / 109 会话 / 53 命令） |
| 读接口隔离 | 已上线：`device` 跨设备读 → `403 device_mismatch`（2026-11-02 13:29 实测） |
| bridge | `{"ok":true,"service":"cline-bridge"}`（手动启动，未开机自启） |
| 线上入口 | `https://hub.littlewish.top:8443` |
| Cline CLI | `3.0.74`（已是最新，`--json` 可用，**没有 `--act`**） |
| Flutter / Dart | `3.47.5` / `13.4` |
| Android 工具链 | SDK `%LOCALAPPDATA%\Android\Sdk`（platforms 33–37 / build-tools 30–37）；JDK 17 与 21 在 `<JDK 目录>\`；`GRADLE_USER_HOME=%USERPROFILE%\.gradle` 已缓存 gradle-9.3.1。**`JAVA_HOME` 为空**，默认 PATH 上是 zulu-8，打包前必须设成 JDK 17 |
| 已跟踪会话 | 109 个（`GET /api/v1/devices` 的 `sessionCount`，2026-11-02 14:19） |
| App 发布版本 | `1.3.0+13`（`GET /api/v1/app/latest` 实测；APK 55,601,168 B，sha256 `c3cca5cb…e179`；2026-11-04 06:37 发布） |

## 2. 里程碑与最近提交

| 里程碑 | 内容 |
|---|---|
| M1 / M2a | Hub 上云 + bridge 远程命令 |
| M2b | Flutter 客户端（会话 / 命令 / 动态 + SSE） |
| M2c | 逐条消息流 + 项目聚合 + 详情页 |
| M3（进行中） | 稳定性与可读性：模式、配色、全文、复制、并发 |

最近 6 个提交：`1e7a46e` 手机发文件 / 图片 + 右侧菜单 + 附件入库时间（P38） → `c9de875` 根 README 使用者视角 + 推送/保活验证（P36/P37） → `7760ace` App 1.1.6+8 发版 + 落地页（P35） → `8a78f40` 锁屏保活 / 同任务通知归并 / 分组带设备（P32–P34） → `a204f62` 历史重写记录（P31） → `4ecadfa` 回填重写后的哈希（P31）。

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
**P1**：P11 → P12 → P13 → P6 → P18 → P7 → P14 → P8 → P19 都已完成（P7/P14 待 bridge 重启生效；
P19 已上线）；下一步候选：真机核对 P2、Web 预览降级（P2 段）、多设备推送（P3 剩余部分）。
**P7 用法**：想并行就把 `bridge/config.json` 的 `commands.concurrency` 设成 2+（上限 8），
同一个 workspace 仍强制串行（ADR-41）。
**P2**：App 无 SSE 的 Web 预览降级体验。
**P3**：多设备。① 读/推按设备隔离（P19/ADR-43）已完成；② App 侧设备过滤（P23）已完成，
只在 ≥2 台设备时出现；③ 新增第二台设备的 runbook（`docs/new-device.md`）与
`GET /api/v1/devices`（ADR-47）已完成；④ 还缺：审计视图细化、按用户隔离（当前 app token 看全部，
见 `docs/self-host.md` §7）。
**P21**：重发脚本只对**本机还有源数据**的会话有效；旧会话被 Cline 清掉后就补不了（见 §5.15）。

## 5. 已知坑（别重复踩）

1. **CLI 没有 `--act`**：`modeExplicitlySet` 只认 `--plan/--yolo/--zen`，否则模式取 `settings/global-settings.json` 的 `planActMode` → 手机发 act 也会跑成 plan。修法见 `command-worker.js` 的 `clineModeEnv()`。
2. **`--id` 续会话要 TTY**：无头只能 `-c <workspace>` 新开会话。
3. **`spawn` 必须 `stdio: 'ignore'`**：否则 cline 等 stdin，命令永远「执行中」。
4. **prompt 单个词会被当子命令**：不带空格时补尾随空格（`c3ee1da`）。
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
15. **重发补不了「本地已删」的会话**：`npm run resend` 读的是本机 `sessions.db` +
    `messages.json`，Cline 清理过的会话（实测 6 条 11-01 的旧会话，97 条本地 vs 106 条线上）
    只能报「跳过」。要补只能一次性改库回填 `project*`，别再指望重发。
    `--missing-project` 的判据是 `project` 与 `projectKind` **都为空**：散会话
    （`projectKind=loose`）的 `project` 本来就是空，按 `project` 筛会多推二十多条。
16. **命令列表只有最近 50 条**（`GET /commands?limit=50`），设备过滤也只筛这 50 条：
    「切到某台设备后看不到命令」可能只是它不在最近 50 条里，不一定是 bridge 没跑。
17. **本机到 GitHub 的 22 端口会被拒**（`ssh: connect to host github.com port 22: Connection refused`，
    2026-11-03 实测）：不换远端，改走 443 通道——
    `git config url."ssh://git@ssh.github.com:443/".insteadOf "git@github.com:"`，
    之后 `git push origin master` 直接可用（首次会写 `known_hosts`）。

## 6. 自检命令

```powershell
cd bridge; node --test; node scripts/check-workspace-whitelist.mjs
cd server; npm test; npm run migrate
cd app;    flutter pub get; flutter analyze; flutter test
node site/check-site.mjs
powershell -NoProfile -File deploy/windows/verify-hub.ps1
```

## 7. 文档一致性

- 改行为 → 同步模块 README；用户能感知的能力变化 → 根 `README.md` 的「手机上能做什么」/「功能清单」。
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
| 2026-11-02 | **P19 读接口按设备隔离**：`readDeviceScope()`（device 只能读自己，跨设备 `403 device_mismatch`；app/admin 不传即全部）接入 sessions / messages / commands / hooks；`sseMayReceive()` 让 SSE 按设备过滤；`server/test/scoping.test.mjs` 12 项（server 30 项全绿）；ADR-43；新增根目录 `CHANGELOG.md`；13:28 镜像重建上线（备份 `bak-20261102-132824`），线上 device 跨设备读 `403 device_mismatch` 实测通过 |
| 2026-11-02 | **工作目录去重**：`normalizeFsPath()`（正/反斜杠、重复/尾斜杠；不动大小写、保留 UNC 与盘符根）接入 `POST /sessions` / `POST /commands` / `POST /hooks` 与 `toListItem` / `toCommand` / hook 读取；App `HubStore._pathKey()` 用于分组键与 `knownWorkspaces` 去重；`server/test/paths.test.mjs` 6 项（server 36 项全绿）、`flutter test` 58 项通过；ADR-44。**未部署**：Hub 要重建镜像才生效；6 条旧会话 `project*` 仍空（需 bridge 重发） |
| 2026-11-02 | **P20 上线**：只覆盖 `server/src/util.js` + `routes/{sessions,commands,hooks}.js`（备份后缀 `20261102-135023`），`docker compose build` + `up -d`；线上 106 条会话里 `workspaceRoot` 含正斜杠的 0 条（部署前 1 条） |
| 2026-11-02 | **P21 重发**：`bridge/src/record.js`（`workspaceName` / `sessionState` / `effectiveStatus` / `toRecord` / `fingerprintOf` 从 `index.js` 抽出）+ `scripts/resend.mjs`（`npm run resend`，删掉只发消息的 `resend-session.mjs`）；`--missing-project` 判据是 `project` + `projectKind` 都为空；5 项 `record.test.mjs`（bridge 53 项全绿）；ADR-45。**实测**：6 条旧会话本地已被 Cline 清掉（97 vs 106），脚本只能跳过 |
| 2026-11-02 | **P22/P23 App**：命令卡片元信息改「项目目录 · 设备 · 相对时间 · 耗时」（`workspaceLabel()`）+ `ElapsedText` 每秒重算；`MetaLine.trailing`；`DeviceFilterBar` + `HubStore.deviceFilter` / `visibleSessions|Commands|Hooks`（≥2 台设备才出现）；`flutter analyze` 无告警、`flutter test` 64 项通过；ADR-46。**未发版** |
| 2026-11-02 | **P24 设备列表接口**：`GET /api/v1/devices`（auth any；device 只看自己、app/admin 看全部电脑端；`lastSeenAt` / `sessionCount` / `commandCount` / `pendingCommands` / `runningCommands` / `lastSessionAt` / `lastCommandAt`）；App `DeviceItem` + `HubApi.devices()` + `HubStore.devices`（进 `refreshAll`）/ `deviceLabel()`；设置页「已接入设备」卡片（在线状态 + 计数 + 设为默认）；`server/test/devices.test.mjs` 3 项（server 39 项全绿）、App 新增 3 项（`flutter test` 67 项）；ADR-47；**Hub 已上线**（14:07 镜像重建，旧文件备份 `clients.js.bak-20261102-1407*`），线上 app token 实测返回 `localone` |
| 2026-11-02 | **P25 接入文档**：`docs/new-device.md`（第二台 Windows：建设备 / config 字段 / 起 bridge / 手机确认 / 多机边界 / 排障）、`docs/self-host.md`（从零自托管：Hub + Postgres + Caddy、两类 token、bridge、APK、验收清单、多人边界、升级备份、安全基线）、`bridge/README.md`（配置 / 脚本 / 目录 / 验证）；`docs/README.md`、`AGENTS.md`、`README.md` 加入口 |
| 2026-11-02 | **P26 App 1.1.5+7 发版**：APK 55,239,940 B / sha256 `53a64cd1…d5ac` → `/var/www/cline-hub/app/cline-console-1.1.5.apk`（HEAD 200 / `application/vnd.android.package-archive`）；`/srv/cline-hub/releases/latest.json` 已更新，`GET /api/v1/app/latest` 返回 1.1.5 / build 7 / 三条 notes；`adb devices` 为空，手机走 App 内「检查更新」 |
| 2026-11-02 | **Hub 重部署核对（14:18–14:19）**：先逐文件核对 —— 宿主机 `/srv/cline-hub/server/src`、容器内 `src` 与本地工作区 16 个 `*.js` 的 sha256 全部一致（`http.js` / `auth.js` 仅行尾 CRLF 差异），`scripts/*.mjs` 也一致；`docker compose build` 全命中缓存（同一镜像 ID，`up -d` 判定无需重建）；`migrate` 输出 `migrations up to date {"total":8}`；用 `up -d --force-recreate hub` 真正重启容器（`Up 5s`、health `uptimeSec=5`、`sseClients` 自动回到 1）；线上 `node server/scripts/smoke.mjs` **22/22 通过**（含两条新增 `/devices` 检查与 SSE 命令事件）；109 条会话里 `workspaceRoot` 含正斜杠 **0 条**（4 组：49/35/21/4）；smoke 留下的 `cmd_b9fa6fb6e797`（无 workspace）被 bridge 判 `failed: no usable workspace`，没有真起 cline |
| 2026-11-02 | **推到 GitHub（P27）**：新建**私有**仓库 `ANMDJ/cline-hub`（`gh` 2.103.3 用 `winget` 装到 `C:\Program Files\GitHub CLI\`；设备流第一次卡在 `github.com/login/oauth/access_token` 超时，改走本机代理 `127.0.0.1:7897` 后以账号 `ANMDJ` 授权成功，scopes `repo`/`read:org`/`gist`）；`origin` = `git@github.com:ANMDJ/cline-hub.git`，`master` 已推送（`817f418`）并设上游；仓库本地 `core.sshCommand` 钉到 `~/.ssh/id_github_work`（默认 `id_ed25519` 是另一把密钥）；推送前核对：179 个跟踪文件 / 2.5 MiB 对象库，无 `bridge/config.json`、`.secrets/`、`server/.env`、`*.pem` 被跟踪；`site` 的 4 个 `data-todo="repo"` 链接**未**替换（仓库仍私有，转公开再改） |
| 2026-11-02 | **仓库转公开 + 落地页填链接（P28）**：`gh repo edit --visibility public`（`ANMDJ/cline-hub`）；`site/index.html` 三处 `data-todo="repo"` 占位（顶栏 / CTA「看源码」/ 页脚）换成 `https://github.com/ANMDJ/cline-hub` 并**去掉 `data-todo`**（否则 `app.js` 会 `preventDefault` 弹「地址还没填」），`app.js` 注释改为「只兜 fork 后的占位」；`site/README.md` / `README.md` / `AGENTS.md` 更正「4 个占位 / 仓库还是私有」的过期说法（实际 3 处）；服务器 IP 与域名**未脱敏**（`hub.littlewish.top` 的 A 记录本就直指该 IP，仓库里藏它没有安全意义） |
| 2026-11-02 | **落地页对齐 1.1.5 + 接上仓库（P29）**：`site/index.html` 按当前版本重写 —— Hero 按钮「五分钟自建 / 下载 App 1.1.5（`/app/cline-console-1.1.5.apk`）/ GitHub 源码」，facts 换成 `1.1.5` + `22/22`；特性卡 6→8（远程命令与取消、模板化执行 · 并发池、多设备、结构化输出、8 个迁移、22 项冒烟）；架构三段补 `messages.json` / `devices` / Markdown / 设备筛选 / `pid` 对账；快速开始 `git clone` 填真仓库、冒烟输出改 `22/22`；进度表 M2b/M2c 完成、M3 进行中（剩 FCM 与审计视图）；FAQ 加「APK 在哪下载」；页脚接仓库 + CHANGELOG + 版本号。`site/check-site.mjs` 增加 `/app/*` 运行时白名单（APK 由 Caddy 直出、不在 `site/` 里，否则误报「文件不存在」）；`site/README.md` 记下「版本 / APK 路径共 6 行 9 处，发版一起改」。`node site/check-site.mjs` 通过；**已发版**：`tar` → `scp` → 服务器解包（备份 `/tmp/site-backup-20261102-153423.tgz`，文件 chmod `644`），线上 `http://82.157.153.22/` 实测 200、`1.1.5`×9、`22/22`×2、APK 链接×3、`data-todo` 残留 0、APK HEAD 200 |
| 2026-11-02 | **脱敏本机路径（P30）**：公开仓库里写死的个人绝对路径全部换掉 —— Windows 用户目录统一写成 `C:\Users\alice`（代码注释 / 接口示例 / 测试夹具，大小写用例同步成 `ALICE` 以保留「不动大小写」的断言）、Git Bash 的 `/c/Users/<账号>/...` → `<仓库>`、Android SDK / Gradle / JDK 的本机绝对路径 → `%LOCALAPPDATA%\Android\Sdk` / `%USERPROFILE%\.gradle` / `<JDK 17 路径>`、`Downloads\kids_privae.pem` → `<下载目录>/kids.pem`。`deploy/windows/ClineBridge.vbs` 改为顶部 `REPO` 常量 + 拼接（它会被复制进「启动」文件夹，无法靠脚本自定位；同时 `README.md` 里的同款片段同步）。`AGENTS.md` 仓库根改成「当前目录 + `<仓库>` + `%USERPROFILE%` 示例」，`docs/bridge-notes.md` 的本机账号改成 `<你的账号>`；`LICENSE` 的版权署名保留（那是作者名，不是路径）。回归：server **39/39**、bridge **53/53**、whitelist 自检 **10/10**、App `flutter test` **67 通过 / 5 跳过**、`node site/check-site.mjs` 通过 |
| 2026-11-02 | **P32 同任务通知归并**：`HubStore._notifiedTasks`（`sessionId → 首次提醒时间`，窗口 15 分钟）把 `command.update` 终态与 bridge 30 秒稳定后合成的 `session_done` 归并成「一条任务」；先到哪条弹哪条，另一条静默。修「息屏 → 回前台同一任务两条通知」；`flutter test` 71 通过 / 5 跳过（新增 3 条归并用例）；ADR-48 |
| 2026-11-02 | **P33 分组显示来源机器**：`HubStore._groupKey()` 改成 `<deviceId>\|<项目键>`（两机同名项目分成两组），`SessionGroup` 加 `deviceId` / `loose`，`sessionGroups` 走设备过滤；`WorkspaceGroupHeader` 增加设备 Pill、`SessionTile` 元信息补 `设备 …`（多设备时）；`flutter test` 71 通过 / 5 跳过；ADR-49 |
| 2026-11-03 | **P34 锁屏保活（形态 B）**：新增 `KeepAliveService.kt`（`dataSync` 前台服务 + 静音常驻通知，通道 `cline_hub_keepalive` / id `7301`，`START_NOT_STICKY`、`stopWithTask`、Android 15 `onTimeout` 收工）；`AndroidManifest` 加 `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_DATA_SYNC` 与 service 声明；`MainActivity` 的 `…/notify` 通道加 `startKeepAlive` / `stopKeepAlive`（`IllegalStateException` / `SecurityException` 一律降级为 false）；`HubNotifier` 加两个默认空实现的方法，`SettingsStore.keepAliveEnabled`（`notify.keepAlive`，默认开）；`HubStore._syncKeepAlive()` 在活跃命令 0→1 开、归 0 / 401 / 关开关 / `dispose` 停（回前台不主动停，避开 Android 11+ 后台启动限制），设置页「通知」卡片加「锁屏也提醒」开关；版本 `1.1.6+8`；`flutter analyze` 无告警、`flutter test` **78 通过 / 5 跳过**（新增 7 条保活用例）；ADR-50。**待真机验证**（锁屏收通知 / 常驻通知消失 / 划掉任务） |
| 2026-11-02 | **重写历史清掉本机路径（P31）**：用 `git-filter-repo`（单文件脚本，不装进系统环境）对全部提交做 blob 级替换 —— Windows 用户目录（含 JSON 里 4 层反斜杠变体）→ `C:\Users\alice`，全大写变体单独映射成 `ALICE`；Git Bash 的 `/c/Users/<账号>/...`（两种旧目录形态 `~/.cline/...` 与 `~/projects/...`）→ `<仓库>`；`D:\Android\Sdk` / `D:\android\.gradle` / `D:\Program Files\java\jdk-17` / `D:/android/sdk` → 环境变量写法；反引号包着的账号名 → `alice`。`LICENSE` / `README` 的版权署名保留（作者名不是路径）。重写前 `git bundle` 备份到仓外临时目录；重写后 HEAD tree 与重写前**逐字节一致**（`6e4eca45`），即只改了历史、当前内容未变。随后按 `commit-map` 把 `docs/status.md` 里 8 处旧短哈希回填成新哈希（例：`a20abe1`→`c3ee1da`），`git log -S'<旧用户目录>'` 全历史 **0 命中**。⚠️ 实测 GitHub 仍能按 SHA 直接访问强推前的旧提交（HTTP 200 且内容含旧路径），彻底清掉必须删仓重建 —— `delete_repo` scope 待授权 |
| 2026-11-03 | **P35 App 1.1.6+8 发版 + 落地页对齐**：`cd app; node scripts/release-apk.mjs --skip-build`（复用已构建的 `app-release.apk`，先用 `output-metadata.json` 核对 versionName `1.1.6` / versionCode `8`）生成 `dist/cline-console-1.1.6.apk` + `dist/latest.json`（sha256 `4ecaf2f3…4173`）；`scp` 后 `sudo install` 到 `/var/www/cline-hub/app/`（HEAD 200 / `application/vnd.android.package-archive` / 55,256,496 B）与 `/srv/cline-hub/releases/latest.json`（`GET /api/v1/app/latest` 返回 1.1.6 / build 8 / 三条 notes，Hub 不用重启）；`site/index.html` 9 处版本号 + M3 进度 + 「实时下行」补锁屏保活说明、`site/README.md` 同步；`node site/check-site.mjs` 通过，逐文件 `scp` + `sudo install` 发布（本机 `tar.exe` 被系统拒绝 `Access denied`，改用单文件 scp；旧页面备份 `/tmp/site-backup-20261103-082841.tgz`），线上 `http://82.157.153.22/` 200 / 19351 B、`1.1.6`×9、`1.1.5`×0；`adb devices` 为空，手机走 App 内「检查更新」 |
| 2026-11-03 | **P36 根 README 改成使用者视角**：开源首页原来按开发过程写（端口表 / 备案与 8443 入口 / 证书续期 / 安全基线复盘 / 里程碑 / bridge 脚本细节），第一次看到项目的人信息过载。重写为「它做什么 → 怎么做的（上行 / 下行 + 实时性三层）→ 手机上怎么用（三个 Tab + 设置 + 多设备）→ 功能清单（采集 / 远程命令 / App / Hub / 安全边界）→ 自己跑一套（指向 self-host / new-device / api）→ 已知边界」，**423 行 → 201 行**；运维事实留在原地（`docs/status.md` §1/§3/§5、`deploy/README.md` §11、ADR-11 / 20、`bridge/README.md`、`docs/self-host.md` §9），没有删除任何独占信息；同步 `docs/README.md` / `AGENTS.md` 的文档地图、`deploy/README.md` 的交叉引用、本文件 §7 的文档一致性规则 |
| 2026-11-03 | **P38 右侧菜单**：设备列表与设置入口从顶栏 / 设置页挪进 `Scaffold.endDrawer` —— 新增 `ui/home_drawer.dart`（电脑列表带在线状态、会话 / 待执行 / 执行中计数，点一台设为默认，另有「刷新数据 / 设置」），`home_shell.dart` 顶栏改为「连接状态 + 菜单按钮」，打开抽屉时顺手 `refreshDevices()`；`HubStore.setDefaultDevice()` 补一次 `notifyListeners()` |
| 2026-11-03 | **P38 发送文件 / 图片**：migration `009_attachments.sql`（`attachments` 表 + `commands.attachment_id`）；`POST /api/v1/attachments`（base64 JSON，`HUB_MAX_ATTACHMENT_BYTES` 默认 8 MB，同设备同名同哈希复用；`http.js` 支持按路由覆盖 body 上限）、`GET /api/v1/attachments/:id`（device 只能取自己的）；`POST /commands` 允许「只带附件」，`toCommand()` 返回 `attachment` 元数据；bridge 新增 `src/attachment.js`（下载 → `%TEMP%\cline-hub-cmd\incoming\<commandId>-<文件名>` → 绝对路径拼进 prompt，失败直接 `failed`）；App 新增 `data/file_picker.dart`（原生 `ACTION_OPEN_DOCUMENT`，不引 file_picker）、`ui/attachment_bar.dart`，下发面板与会话输入框都能「选文件 + 写一句要它做什么（可留空）」，命令卡片 / 详情显示附件行；ADR-52 / 53 |
| 2026-11-03 | **P38 验证**：`cd server; npm test` **47 通过**（新增 9：文件名清洗 / base64 / 413 / 复用 / 设备归属 / 下载 scope / 只带附件下发）、`cd bridge; npm test` **59 通过**（新增 6：安全文件名 / 大小文案 / prompt 拼装 / 下载落盘 / 404·空·超限）、`cd app; flutter analyze` 无告警、`flutter test` **86 通过 / 5 跳过**（新增 8：格式 / 模型 / 上传→下发 / 选择器降级 / 面板按钮 / 右侧菜单）。**待部署**：迁移 009 + Hub 镜像重建 + bridge 重启 + App 发版 |
| 2026-11-03 | **P37 推送 / 保活验证（不接厂商通道）**：`adb devices` 为空，把不依赖真机的部分全做了 —— ntfy 发布 `HTTP 200`（`id=dlyLaLiL8GFm`，0.76s，与 `hooks/_notify.ps1` 同一条路径）；app token 连 `GET /api/v1/events` 27 秒收到 `: connected` + 2 条 `event: messages` + 一次 `: ping`（鉴权 / 设备过滤 / 反代不缓冲）；`app/dist/cline-console-1.1.6.apk` 的 sha256 `4ecaf2f3…4173` / 55,256,496 B 与线上 `Content-Length` 一致，`aapt2` 确认 `KeepAliveService`（`foregroundServiceType=0x1`、`stopWithTask=true`）与 `POST_NOTIFICATIONS` / `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_DATA_SYNC` 都在；基线 bridge 53 / server 39 / app 78+5 / site ✓。P2 由用户在真机确认「两个按钮的对比没问题」，关闭；用户拍板**不接 FCM / 厂商推送**（ADR-51）；P34 真机 7 条仍待手机，排障入口写进 `app/README.md`；`site/index.html` 的 M3 进度把「剩真正的后台推送（FCM）」改成「明确不接 FCM / 厂商通道（ADR-51）」，但本机会话没有服务器 SSH 私钥（`Permission denied (publickey)`），**线上落地页未更新**，拿到权限后逐文件 `scp` + `sudo install` |
| 2026-11-03 | **附件入库时间**：`toAttachment()` 增加 `createdAt`（= `attachments.created_at`），命令列表 / 详情的 `withAttachments()` 与上传 / 复用查询都带 `created_at`；App `AttachmentInfo.createdAt`（旧 Hub 缺字段时为 null）+ 命令详情「入库 MM-dd HH:mm:ss」；**保留策略按用户要求暂不做**（只记录、不清理），`docs/api.md` / ADR-52 写明以后按这一列算。验证：server **47** / bridge **59** / app `flutter analyze` 无告警 + `flutter test` **86 通过 / 5 跳过** / `node site/check-site.mjs` 通过 |
| 2026-11-03 | **P38 部署 + App 1.1.7+9 发版**：`scp` 6 个文件 → 备份 `server.bak-20261103-122537` → `docker compose build` → 迁移 `009_attachments.sql`（`migration applied`）→ `up -d --force-recreate hub`（health 200 / `routes: 22`）；线上 app token `POST /api/v1/attachments`（`smoke-p38.txt` 9 B）返回 **`createdAt=2026-11-03T04:26:08.838Z`**（= 12:26 +08 入库），device token `GET /api/v1/attachments/:id` 200 / 9 B，`GET /commands` 多出 `attachment` 字段；APK `1.1.7+9`（55,568,256 B / sha256 `4261c8f2…ee25`）→ `/var/www/cline-hub/app/`（HEAD 200 / `application/vnd.android.package-archive`）与 `/srv/cline-hub/releases/latest.json`（`GET /api/v1/app/latest` → 1.1.7 / 9 / 3 notes）；落地页 `1.1.7`×9 / `1.1.6`×0（`http://82.157.153.22/` 200）；bridge 用 `npm run restart:idle` 排空闲重启（supervisor pid 3260，日志 `waiting for in-flight commands`；要等 `cmd_10e3f1f2394f`（kids_points_app）与当前会话两条都结束后才动手，超时 2 小时不动）（代码提交 `1e7a46e`） |
| 2026-11-03 | **品牌定为 ClineHub（A 层 · 仅展示文案）**：`Cline Console` / `Cline Console Hub` / `Cline Hub` → **ClineHub**（同日先改 `CloudHub`，按用户要求再定为 `ClineHub`），覆盖根 README、`AGENTS.md` 与 `docs/README.md` 的 ADR 计数、`app/README.md`、`bridge/package.json` 与 `server/package.json` 的 description、server 三条迁移注释、站点（title / description / og:title / 导航 wordmark / hero / footer / `app.js` / `styles.css` 注释）、App（`MaterialApp.title`、顶栏、抽屉、引导页、设置页版本行、Web `index.html` + `manifest.json`、Android `android:label`、通知标题与默认标题、`KeepAliveService` 常驻通知）、`deploy`（Caddyfile 注释 / README 实测样例 / `verify-hub.ps1` 两处输出）。**未改任何标识符**：`cline_console` 包名与 `applicationId`、`cline_hub` 库 / 角色、`HUB_*` / `CLINE_HUB_*` 环境变量、`/var/www/cline-hub`、`/srv/cline-hub/releases`、`%TEMP%\cline-hub-cmd`、`ANMDJ/cline-hub`、APK 文件名、`ClineConsoleApp` 类名、通知通道 id；`docs/security-review.md` 的「官方 Cline Hub」与 CVE 标题、ADR-21 的 cline CLI hub daemon 引用保持原样。ADR-57 / ADR-58（本轮只改仓库文案，未重建 APK、未重新部署 Hub / 站点）|






| 2026-11-03 | **P39 浏览入口收进右侧抽屉 + 设置页去重**：`ui/home_drawer.dart` 新增「浏览」区 —— 「按工作区浏览」（`onOpenWorkspaces` 由 `HomeShell` push，先 pop 抽屉）+ ≥2 台设备时的 chip（「全部设备 / 每台」，只改 `HubStore.deviceFilter`，不动 `settings.deviceId`）；设备行离线时补「X 小时前上报」；`ui/widgets.dart` 的 `DeviceFilterBar` 换成 `ActiveDeviceFilterBar`（`deviceFilter == null` 时零高度，筛选生效才出现「只看 X + 看全部设备」）；`sessions_page.dart` 删掉顶部工作区按钮，会话 / 命令 / 动态三页只保留提示条；`settings_page.dart` 删掉与抽屉重复的「已接入设备」卡片及 `_devicesBody` / `_deviceRow` / `_refreshDevices` / `_loadingDevices`，「默认执行设备」改名「手填兜底」（设备没上报过时仍可填）；「安全提示」按线上 `https://hub.littlewish.top:8443` 现状改写（原文还写着「IP + 随机前缀的明文 HTTP / 等备案」）；`SectionCard` 内容补一层透明 `Material`，消掉卡片里 `SwitchListTile` 触发的 debug 断言（水波纹不可见）；ADR-54。验证：`cd app; flutter analyze` 无告警、`flutter test` **88 通过 / 5 跳过**（抽屉用例扩到 chip 筛选 / 工作区入口 / 离线多久没上报；新增「提示条只在筛选时出现」「设置页不再放设备列表」2 条） |
| 2026-11-03 | **App 1.1.8+10 发版（P39 上线）**：`pubspec.yaml` / `app_version.dart` 1.1.7+9 → 1.1.8+10（`kChangelog` 补 1.1.8 四条）；`JAVA_HOME=<JDK 17 路径>` + `ANDROID_HOME/ANDROID_SDK_ROOT=<Android SDK>` 后台构建（`assembleRelease` 57.8s）→ `aapt2` 核对 `versionCode=10` / `versionName=1.1.8`；`release-apk.mjs --skip-build` 出清单（sha256 `a17a2ca0…a314`，55,568,256 B）；`ssh -i ~/.ssh/kids.pem` 上传 APK 到 `/var/www/cline-hub/app/cline-console-1.1.8.apk`（`caddy:caddy 644`）、清单到 `/srv/cline-hub/releases/latest.json`；落地页 `site/index.html` 六处版本引用改 1.1.8（`node site/check-site.mjs` 通过、无 BOM）并 install 到 `/var/www/cline-hub/index.html`。线上验证：`GET /api/v1/app/latest` → 1.1.8 / 10 / sha 一致；`HEAD /app/cline-console-1.1.8.apk` → 200 / `application/vnd.android.package-archive` / 55,568,256 B；`http://82.157.153.22/` 显示 1.1.8 ×9、APK 链接 200。bridge（3210）与 Hub（health 200 / db 1ms）本来就在跑，无需重启（代码提交 `7a75eb1`） |
| 2026-11-03 | **安全审计复核（只写文档）**：手机发来的 `cline-hub 安全审计与加固建议.docx` 逐条回代码核对 —— 说对 7 条（SKIP LOCKED 短事务 / token 只存哈希 / 单租户 / 线上只监听回环 / 无租约…），说错或夸大 4 条（**SSE 其实有 25s 心跳**；CVE-2026-59723 实为 8.8 / `AV:A`、影响 `cline dashboard` 且本机 `cline 3.0.74` 已修；XFF 是「取第一段」错而非「采信条件」错；Origin 该从 🔴 降到低/中 —— 凭据是 bearer 没有 cookie 可被自动携带），漏掉 4 条（**SSE 的 token 在 URL 里会进 access log**、命令回写是无条件 UPDATE、附件无配额、health 泄露 `sseClients`）。新增 `docs/security-review.md` + ADR-55，`status.md` 登记 P40–P43（**均未开工**）；按用户拍板**不动行为代码**。验证：`flutter analyze` 无告警、`flutter test` **88 通过 / 5 跳过**；另打了 P39 预览包 `app/dist/cline-console-1.1.7-preview-p39.apk`（55,568,256 B / sha256 `bc1dc4c0…b762` / `versionCode=10`），**未能上传服务器**（本机无 SSH 私钥） |

| 2026-11-03 | **P44 DeepSeek 余额（代码 + 测试，未上线）**：新增 `server/src/routes/deepseek.js` —— `GET /api/v1/deepseek/balance`（`auth: app`）代查 `GET https://api.deepseek.com/user/balance`，Key 只读 `DEEPSEEK_API_KEY`，**不下发、不写日志**；进程内 60 秒缓存 + `inflight` 并发复用 + `?refresh=1` 绕过；上游 401/403 转 `502 deepseek_auth_failed`（不能透传 401，否则 App 会把它当成自己的 Hub token 失效）、429 → `deepseek_rate_limited`、超时 → `504 deepseek_timeout`、出网失败 → `503 deepseek_unreachable`；没配 Key 返回 200 + `configured:false` + `hint`；刷新失败但有旧数据时返回旧数据 + `stale:true`；金额保持字符串，服务端不做浮点运算。App：`models.dart` 新增 `DeepSeekBalance` / `DeepSeekBalanceInfo`（`¥` / `$` 按币种、`充值 x · 赠金 y`）、`HubApi.deepseekBalance()`、`HubStore.balance / loadingBalance / balanceError / refreshBalance({force})`（并发只跑一条）、`HomeDrawer` 顶部 `_BalanceCard`（未配置 / 查询中 / 失败 / 有数字四种状态）；刷新时机 = 启动与回前台（`refreshAll`）、打开右侧菜单、命令走到终态（`_maybeNotifyCommand`）、卡片右上角手动刷新。契约见 `docs/api.md`，环境变量见 `server/.env.example` / `server/README.md`，ADR-56。验证：`cd server; node --test` **56 通过**（新增 10 条：未配置 / 解析与脱敏 / 缓存与 `refresh=1` / 并发复用 / 401 / 429 / 网络 / 退旧值 / 坏 payload）；`cd app; flutter analyze` 无告警、`flutter test` **97 通过 / 5 跳过**（新增 9 条） |

| 2026-11-03 | **P44 上线 + App 1.1.9+11 发版**：服务器 `/srv/cline-hub/server/.env` 写入 `DEEPSEEK_API_KEY`（`600`，Key 不进仓库 / 不进 APK / 不进日志）；上传 `src/env.js`、`src/routes/index.js`、新增 `src/routes/deepseek.js`（备份后缀 `20261103-194741`）→ `docker compose build` + `up -d --force-recreate hub`（23 条路由，容器内 `printenv DEEPSEEK_API_KEY` 有值，容器与宿主机 `deepseek.js` sha256 一致）。线上实测：`GET /api/v1/deepseek/balance` → `configured:true` / `CNY 14.37` / `isAvailable:true`（首次 196ms；60 秒内第二次 `cached:true`；`?refresh=1` 84ms 重新打上游；响应体不含任何 token）。App：`pubspec.yaml` / `app_version.dart` 1.1.8+10 → **1.1.9+11**（`kChangelog` 补 1.1.9 三条），`JAVA_HOME=<JDK 17>` 后台构建（`assembleRelease` 127.2s）→ `aapt2` 核对 `versionCode=11` / `versionName=1.1.9`；`release-apk.mjs --skip-build` 出清单（sha256 `17f49c12…a13c`，55,601,136 B）；上传 APK 到 `/var/www/cline-hub/app/cline-console-1.1.9.apk`（`caddy:caddy 644`）、清单到 `/srv/cline-hub/releases/latest.json`（4 条 notes，Hub 现读不用重启）；落地页 `site/index.html` 六处版本引用改 1.1.9 + M3 里程碑补「DeepSeek 余额已上线」（`node site/check-site.mjs` 通过、无 BOM）并 install 到 `/var/www/cline-hub/index.html`。线上验证：`GET /api/v1/app/latest` → 1.1.9 / 11 / sha 一致；`HEAD /app/cline-console-1.1.9.apk` → 200 / `application/vnd.android.package-archive` / 55,601,136 B；`http://82.157.153.22/` 显示 1.1.9 ×9、无 1.1.8 残留。测试基线：`cd server; node --test` **56 通过**、`cd app; flutter analyze` 无告警、`flutter test` **97 通过 / 5 跳过**。剩余：手机装 1.1.9 后确认抽屉卡片显示 ¥14.37 |
| 2026-11-04 | **品牌统一为 ClineHub（A 层）+ App 1.2.0+12 发版**：提交 `63488a9`（34 个文件，改动全是展示字符串）→ 推送 `origin/master`（`ssh.github.com:443`）。站点：`site/{index.html,styles.css,app.js}` `scp` 到 `/tmp` 后 `install -o caddy -g caddy` 到 `/var/www/cline-hub/`（三个文件 md5 与本机一致；`http://82.157.153.22/` 200 / 19,392 B，title 已是 ClineHub；`https://hub.littlewish.top:8443/` 仍是 404，站点只在 IP 站，符合预期）。APK：`JAVA_HOME=D:\Program Files\Java\jdk-17` 后台 `flutter build apk --release --build-name=1.2.0 --build-number=12`（`assembleRelease` 158.3s）→ `aapt2 dump badging` 核对 `versionCode=12` / `versionName=1.2.0` / `application-label=ClineHub`；`release-apk.mjs --skip-build` 出清单（sha256 `fb543395…8901` / 55,601,132 B）；上传到 `/var/www/cline-hub/app/cline-console-1.2.0.apk`（`caddy:caddy 644`，md5 `a0e4e7ab…7738` 与本机一致）与 `/srv/cline-hub/releases/latest.json`（3 条 notes，Hub 现读不重启）。线上验证：`GET /api/v1/app/latest` → 1.2.0 / 12 / sha 一致；`HEAD /app/cline-console-1.2.0.apk` → 200 / `application/vnd.android.package-archive` / 55,601,132 B；Hub health 200（`db 0ms`）；`GET /deepseek/balance` 仍 `configured:true`（CNY 10.85，回归通过）；`deploy/windows/verify-hub.ps1` **failed=0 / warnings=0 / RESULT OK**。**顺手修了一处真回归**：`app/test/app_update_test.dart` 把「更高版本」硬编码成 `1.2.0`，版本号升到 1.2.0 后断言变 false → 改成按 `kAppVersion` 主版本 +1 推导，发版不再自撞。测试基线：`cd server; node --test` **56 通过**、`cd bridge; npm test` **59 通过**、`flutter analyze` 无告警、`flutter test` **97 通过 / 5 跳过**、`node site/check-site.mjs` ✓。Hub / bridge 无行为代码改动，未重建镜像、未重启 bridge。剩余：手机装 1.2.0 后确认桌面图标名与通知显示 ClineHub |
| 2026-11-04 | **P46 微信式输入条**：新增 `app/lib/src/ui/chat_composer.dart`（左侧「+」就地展开「图片 / 文件」、圆角输入框、右侧发送；已选附件显示缩略图 / 名字 · 大小并可移除；空内容发送键禁用；点输入框自动收起面板）；会话详情 `_ComposerBar` 与下发面板共用，`attachment_bar.dart` 删掉 `AttachmentBar`，只留 `pickAttachmentForCommand()` / `attachmentSummary()`；下发面板用 `showSendButton:false`（仍由底部「下发」提交）。验证：`flutter analyze` 无告警、`flutter test` **101 通过 / 5 跳过**（新增 `test/chat_composer_test.dart` 4 项；`attachment_test` 改成先点「+」再断言图片 / 文件；`session_detail_test` 在 `enterText` 后补一次 `pump()`），ADR-59 |
| 2026-11-04 | **P47 命令租约（P42 落地）+ Hub 部署**：`migrations/010_command_lease.sql`（`commands.lease_expires_at` + 活状态部分索引）；新增 `server/src/lease.js`（每 60s `for update skip locked` 选过期行 → delivered/running → failed、cancelling → cancelled，清空租约并广播**带附件**的 `command.update`；启动先扫一次 + `timer.unref()`）；新增 `POST /api/v1/commands/:id/heartbeat`（device：只续租、不改状态、不推 SSE；已结束返回 `finished:true`；跨设备 403）；认领 `pending` 写租约、`PATCH running` 续租、终态清空；**终态不再接受 `running`**（`ignored:true`，防回收后旧 bridge 复活）；`HUB_COMMAND_LEASE_SEC` / `HUB_COMMAND_LEASE_SWEEP_SEC`（默认 120 / 60）。bridge 每 30s 调心跳（`commands.leaseHeartbeatMs`，覆盖跑着 / 占槽位 / 排队的命令，空闲零请求）。部署：`scp` → 备份 `server.bak-20261104-063124` → `docker compose build` → `run --rm hub node src/migrate.js`（`migration applied 010_command_lease.sql`）→ `up -d --force-recreate hub`（**`routes: 24`**、`command lease sweeper started {"everySec":60}`）。线上实测：`POST /commands/cmd_31d24a702889/heartbeat` → `{"ok":true,"finished":false,"leaseExpiresAt":"2026-11-03T22:34:26.152Z"}`；插入一条 `lease_expires_at = now() - 1min` 的 running 自检行 → 22:33:02 被扫成 `failed`（`error_text` 为租约说明、`finished_at` 写入），随后删除自检行。验证：`cd server; node --test` **65 通过**（新增 9）、`cd bridge; node --test` **61 通过**（新增 2）。**bridge 仍是旧代码**，要在两条在跑的命令结束后 `npm run restart:idle` 排空闲重启（旧命令 `lease_expires_at` 为 NULL 不参与回收，不会误杀），ADR-60 |
| 2026-11-04 | **App 1.3.0+13 发版 + 站点**：`pubspec.yaml` / `app_version.dart` 1.2.0+12 → **1.3.0+13**（`kChangelog` 补 1.3.0 三条）；`JAVA_HOME=D:\Program Files\Java\jdk-17` + `ANDROID_HOME=D:\android\sdk` 后台构建（`assembleRelease` 16.7s，命中缓存）→ `aapt2` 核对 `versionCode=13` / `versionName=1.3.0` / label `ClineHub`；`release-apk.mjs --skip-build` 出清单（sha256 `c3cca5cb…e179` / 55,601,168 B / 3 条 notes）；上传 `/var/www/cline-hub/app/cline-console-1.3.0.apk`（`caddy:caddy 644`）与 `/srv/cline-hub/releases/latest.json`。线上验证：`GET /api/v1/app/latest` → 1.3.0 / 13 / sha 一致；`HEAD /app/cline-console-1.3.0.apk` → 200 / `application/vnd.android.package-archive` / 55,601,168 B；`http://82.157.153.22/` 200、`1.3.0` ×9、`1.2.0` ×0、`ClineHub` ×5（`node site/check-site.mjs` 通过）。bridge 已用 `npm run restart:idle` 排空闲重启（supervisor pid 6376，见 `docs/interruptions.md`） |





