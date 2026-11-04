# 安全审计复核（2026-11-03）

> **对象**：手机发来的 `cline-hub 安全审计与加固建议-50954e07.docx`（该文档自称审计日 2026-11-02，
> 方式是「基于仓库文档、目录结构与公开代码的静态审计」，明确未做动态渗透、未逐行审计）。
>
> **本文范围**：只回答两件事 —— ① 它说的对不对；② 要不要据此改本项目。
> **初版（2026-11-03）不含任何行为代码改动**；P40–P43 已于 2026-11-04 实施
> （ADR-63 / ADR-64 / ADR-65，见 §5 的 ✅ 标记）。
>
> **复核方式**：逐条回到 `server/` `bridge/` `app/` 源码对行核对 + 4 项可复现实测（§4）。

## 0. 一页结论

| 维度 | 结论 |
|---|---|
| 结构与方向 | ✅ 靠谱。文件名（`src/net.js`、`FOR UPDATE SKIP LOCKED`、`create-device`）都指对了，不像凭空编 |
| 事实准确率 | ⚠️ 约 **6/10**。3 处明确错误（心跳 / CVE 定性 / XFF 定性）+ 1 处夸大（把 Origin 定成 🔴 高）+ 1 处漏上下文（执行侧并发已有上限） |
| 遗漏 | ⚠️ 漏了 4 条**本项目真实存在**的面，其中 1 条比它列的 🔴 更该先修（SSE token 在 URL 里） |
| 是否照单改 | ❌ 不建议。整体照做要几十小时，且它排第一的那条在本项目**前提不成立** |
| 建议做法 | ✅ 只做 4 项（P40–P43，见 §5），其余明确不做并写清理由 |

**一句话**：**可以当「待办灵感清单」，不能当事实依据**。第 6 节那张「代码审计检查表」有近一半是
通用模板（例如「Caddy 是否限制路径」「是否支持 token 轮换」），与本项目当前实现无关。

## 1. 它说对的（核实为真，附代码位置）

| # | 它的说法 | 核对结果 |
|---|---|---|
| 1 | 命令领取用 `FOR UPDATE SKIP LOCKED`，多实例不会重复领取 | ✅ `server/src/routes/commands.js:201-221`：`select … for update skip locked` + `update … status='delivered'`，**事务里没有执行动作**，提交后才把命令返回 bridge。它担心的「长事务持锁」不存在 |
| 2 | token 只存 SHA-256、比对用 `timingSafeEqual`、明文只打印一次 | ✅ `server/src/auth.js:3`（`hashToken`）、`auth.js:26`（`timingSafeEqual`）、`routes/clients.js:109-120`（明文只出现在 201 响应体）。它说「需确认是否支持轮换」——`server/scripts/rotate-token.mjs` 已经有了 |
| 3 | Hub 默认只监听回环，靠反代对外 | ✅ 代码默认 `server/src/env.js:36`；线上 `server/docker-compose.yml:23,27`（`network_mode: host` + `HUB_HOST: 127.0.0.1`）。**补一句它没提的**：本地开发照 `server/.env.example:7` 是 `HUB_HOST=0.0.0.0`，所以「只监听回环」是**部署姿态**而不是代码强制 |
| 4 | 单租户：一个 app token 能看所有设备、能给所有设备下命令 | ✅ `clients` 表没有 tenant 列，`app` 角色跨设备可读（`routes/clients.js:52-67`）。这是 ADR 明确记录的有意取舍，不是缺陷 |
| 5 | 孤儿命令只靠手动 `npm run reconcile`，没有自动租约 | ✅ `server/migrations/` 里没有 `lease_expires_at` 一类字段；`bridge` 侧只有 `reconcile --dry-run` 手工脚本 |
| 6 | Hub 侧没有按 device 的并发上限 | ✅ `/commands/pending` 只按 `status='pending'` 取，不数 running。⚠️ **但它漏了执行侧**：`bridge/src/command-worker.js:72` `MAX_CONCURRENCY = 8`、`bridge/config.json` 的 `commands.concurrency`（本机 2）、同 workspace 强制串行（ADR-41）。所以「多个 bridge 同时领取会打满本机」这个后果被高估了 |
| 7 | 反向代理信任链是关键边界，`src/net.js` 是重点 | ✅ 定位准确，见 §2.4（它把「哪里错」判错了，但「这块要审」是对的） |

## 2. 它说错 / 夸大的

### 2.1 「SSE 缺少心跳 / 空闲回收」——**心跳有**

- 它有：`server/src/env.js:51` `HUB_SSE_HEARTBEAT_MS`（默认 25000）；`server/src/http.js:229-238`
  每 `heartbeatMs` 给所有连接写 `: ping`，写失败就删连接。线上实测也收到过 `: ping`（`status.md` P37 第 3 项）。
- 它没有（这条后半句是对的）：**空闲超时**、**单 token / 单设备连接数上限**。
  `http.js:241-253` 的 `attach()` 无条件 `clients.add()`，没有配额。

### 2.2 「`HUB_CORS_ORIGIN` 默认 `*` → 跨站 SSE 劫持（🔴 高）」——**前提不成立**

- 事实部分对：`env.js:43` 默认 `*`，`http.js:100` 原样回写 `access-control-allow-origin`；
  `/api/v1/events` 是 `auth: 'any'`（`routes/index.js:34-42`），**没有应用层 Origin / Host 校验**。
- 但它把「官方 Cline Hub 的 WebSocket 劫持」直接类比过来是错的：那类攻击依赖**浏览器自动携带的凭据**
  （cookie / 同源 session）。本项目凭据是 `Authorization: Bearer` 或 `?token=`，**恶意页面拿不到**，
  所以「打开一个恶意网页就能连上你的 SSE 并下发命令」在本项目**不成立**。
- 结论：应降为「低/中 · 纵深防御」，不是 🔴。**顺手可做**（成本 1 小时），但不该排在修 token 泄露前面。

### 2.3 CVE 细节三处不准（实测见 §4.2）

| 它的说法 | 实际 |
|---|---|
| 影响「官方 `@cline/cline-hub` 包」 | 影响的是 **Cline 客户端自带的 `cline dashboard` 本地服务**，发布方 `cline/cline` |
| 端点 `/browser` WebSocket 未校验 Origin | ✅ 这半句对（CWE-346） |
| CVSS **9.7** | **8.8 / HIGH**，`AV:A`（相邻网络）+ `UI:R`，向量 `CVSS:3.1/AV:A/AC:L/PR:N/UI:R/S:C/C:H/I:H/A:H` |
| （隐含）本项目可能受影响 | ❌ 修复版本 `3.0.30`，本机 `cline --version` = **3.0.74**；且本项目的 bridge 用 `cline` 无头执行，**不跑 dashboard**，这个端点在部署里根本不存在 |

### 2.4 「X-Forwarded-For 采信条件写错」——**条件对，取段错**

- 它建议的「只当直连方是回环/受信代理时才信任转发头」，**代码里就是这么写的**：
  `server/src/net.js:21-27` → `isLoopback(direct)` 才看 `x-forwarded-for`。
- 真正的问题在**取第一段**：`forwarded.split(',')[0]`。实测把
  `X-Forwarded-For: 1.2.3.4, 203.0.113.9` 喂进去，返回 `1.2.3.4` —— 正是**攻击者可控**的那一段。
  正确做法是取**反代追加的最后一段**（或多段时从右往左取第一个不在可信网段的）。
- **当前拓扑能不能被利用？不能**：线上 Hub 只监听 `127.0.0.1`，前面的 Caddy 没有配
  `trusted_proxies`，默认会用真实对端地址覆盖该头。但只要**再套一层反代**（CDN / 另一台 nginx）
  或给 Caddy 配了 `trusted_proxies`，`HUB_ALLOW_IPS` 与限流立刻可被伪造。
- 结论：降为「中 · 拓扑脆弱性」，修法是「取最后一段」+ Caddyfile 显式
  `header_up X-Forwarded-For {remote_host}`（把行为钉死，而不是依赖默认值）。

## 3. 它漏掉的（本项目真实存在，按该修的先后排）

### 3.1 🔴 SSE 的 token 在 URL 里 → 会进日志

- 现象：`app/lib/src/data/hub_api.dart:389-393` 用
  `http.Request('GET', _uri('/api/v1/events', {'token': _token}))`；服务端也照收
  （`server/src/http.js:72-77` 的 `bearerToken()` 允许 `?token=`，因为浏览器 `EventSource` 不能带头）。
- 后果：这个 token 会出现在 Caddy access log（`/var/lib/caddy/hub-https.log`、`hub.log`）、
  任何中间层 / 抓包 / 手机崩溃栈里。**这是本项目唯一「长期凭据落进日志」的真实面**，
  比它列的 Origin 严重得多。
- 建议（P41）：`POST /api/v1/sse-ticket` 换 30–60 秒一次性 ticket（库里只存 hash），
  App 拿 ticket 连 SSE；`?token=` 保留一个过渡期后关掉。退一步的止血办法：Caddy 对 query 做脱敏日志。
  **✅ 2026-11-04 已实施**（ADR-64）：60 秒、一次性、只存 `sha256`；App 已改用 `?ticket=`，
  老 APK 仍可用 `?token=`（过渡期）。

### 3.2 🟡 命令状态回写是无条件 `UPDATE`（TOCTOU）

- 现象：`server/src/routes/commands.js:348-362`（`PATCH /commands/:id`）与 `:268-287`
  （`POST /commands/:id/cancel`）都是 `where id = $1`，先 `select *` 再判断，然后无条件写。
- 后果：bridge 回写终态与手机点「取消」并发时，后写的赢；现在只靠 `:319-326`
  「已是 `cancelled` 就原样返回」这一条守卫兜着，不是通用解。
- 建议：改成条件更新 `where id = $1 and status = any($expected)`，`update … returning *`
  为空时按「状态已变」处理（读一次最新值返回，不报 500）。审计文档方向对，但没定位到这里。

### 3.3 🟡 附件无配额、永不清理

- 现象：`server/migrations/009_attachments.sql` + `routes/attachments.js`，单文件上限
  `HUB_MAX_ATTACHMENT_BYTES` 8 MB，**数量不限、无保留策略**（ADR-52 里写明「只记录、不清理」是按用户要求）。
- 后果：风险不是黑客，而是「自己连着发大图 / 视频」把服务器磁盘写满，连带 Postgres 一起挂。
- 建议：先加「按设备 / 全局总字节数」的软上限与 `/api/v1/health` 里的 `attachmentsBytes` 指标，
  再决定要不要自动清理（需要用户拍板，因为清理是不可逆的）。

### 3.4 🟢 `/api/v1/health` 无鉴权且带内部指标

- 现象：`server/src/routes/index.js:9-32`，`auth: 'none'`，返回 `db.latencyMs` / `sseClients` / `uptimeSec`。
- 后果：低（暴露的只是「服务活着 + 大概几条 SSE」）。既然要加固，顺手把 `sseClients` 挪到鉴权后才给。

## 4. 实测记录（都可复现）

### 4.1 `clientIp()` 取第一段

```powershell
cd <仓库>; node -e "import('./server/src/net.js').then(m=>{const req={socket:{remoteAddress:'::ffff:127.0.0.1'},headers:{'x-forwarded-for':'1.2.3.4, 203.0.113.9'}};console.log('claimed ip =',m.clientIp(req))})"
# 输出：claimed ip = 1.2.3.4     ← 攻击者可控段，应为 203.0.113.9 侧
```

### 4.2 CVE-2026-59723 的真实内容

```powershell
(Invoke-WebRequest -UseBasicParsing https://cveawg.mitre.org/api/cve/CVE-2026-59723).Content
```

读到：`title = "Cline: Cross-Origin WebSocket Hijacking in Cline Hub Dashboard (/browser endpoint)"`、
`baseScore 8.8 / baseSeverity HIGH / AV:A`、`affected: cline < 3.0.30`、
`references: GHSA-3cj3-hqcr-g934`。**没有**「9.7」，也**不是** `@cline/cline-hub` 包。

### 4.3 本机 cline 版本不受该 CVE 影响

```powershell
cline --version   # 3.0.74  > 3.0.30
```

### 4.4 复核当天的基线（本轮未改任何行为代码）

| 项 | 结果 |
|---|---|
| `cd app; flutter analyze` | No issues found |
| `cd app; flutter test` | **88 通过 / 5 跳过** |
| 预览包（P39，未发版） | `app/dist/cline-console-1.1.7-preview-p39.apk`，55,568,256 B，sha256 `bc1dc4c0…b762`，`versionCode=10` |
| 服务器 SSH | `ubuntu@82.157.153.22` → `Permission denied (publickey)`（本机无私钥，与 P37 同一阻塞；**线上未做任何变更**） |
| `adb devices` | 空（无设备在线） |

## 5. 采纳计划（只登记，未开工 —— 等用户拍板）

排序原则：**先修「凭据/不可伪造性」，再修「可用性」**，最后才是纵深防御。

| 编号 | 内容 | 工作量 | 为什么排这个位置 | 验收标准 |
|---|---|---|---|---|
| **P40** ✅ | `net.js` 取 XFF **最后一段**；`deploy/Caddyfile` 里 hub 的两个站点（443 / :8443）显式 `header_up X-Forwarded-For {remote_host}`；补 `server/test/net.test.mjs`（首段伪造 / 多段 / 无 XFF / 非回环直连 4 例） | ~30 min | 唯一「拓扑一变即失守」的线路，改动极小 | 伪造 `X-Forwarded-For` 不改变 Hub 看到的 IP；`HUB_ALLOW_IPS` 与限流按真实 IP 生效（**2026-11-04 已实施，ADR-63；测试 7 例**） |
| **P41** ✅ | SSE 短期 ticket：`POST /api/v1/sse-ticket`（60s、一次性、库内存 hash）→ `GET /api/v1/events?ticket=`；App 改用它；`?token=` 留 1 个版本后停用 | 1–2 h（含 App 发版） | 唯一真实的「凭据落日志」面 | access log 里不再出现 `clh_` 前缀；旧 APK 仍能用 token 连（过渡期）（**2026-11-04 已实施，ADR-64**） |
| **P42** | 命令租约：`migrations/010_command_lease.sql`（`lease_expires_at`）+ 每 60s 扫描过期 → `failed: orphaned`；`npm run reconcile` 保留为手动兜底 **（✅ 2026-11-04 已实施，见 ADR-60）** | 2–3 h（含迁移 + 部署） | 它说得对，且你踩过「命令卡 running」 | bridge 硬崩后 ≤2× 扫描周期自动转 `failed: orphaned`，不需要人工 |
| **P43** ✅ | SSE 纵深防御：`HUB_SSE_ALLOWED_ORIGINS`（默认空 = 只拒绝「带 Origin 且跨源」的请求，无 Origin 的客户端照常）+ 单 token 连接上限（默认 8，超限踢最旧）+ 空闲超时（默认 10 min 无写入断开） | ~1 h | 成本低，先把「以后接浏览器端」的坑填了 | 带假 Origin 的 SSE 被 403；连 9 条时最旧一条被踢；`health` 里能看到连接数（**2026-11-04 已实施，ADR-65**） |

> **2026-11-04 更新（P42 已实施）**：`migrations/010_command_lease.sql` + `server/src/lease.js`
> （每 60s 扫过期租约）+ `POST /api/v1/commands/:id/heartbeat`（bridge 每 30s 续租）
> + 终态不接受 `running`；线上已部署（06:31），过期自检行被自动扫成 `failed`。
> **P40 / P41 / P43 已于 2026-11-04 全部实施**（ADR-63 / ADR-64 / ADR-65）：
> XFF 取最后一段 + Caddy `header_up`；SSE 改一次性票据；Origin 白名单 / 单 token 上限 /
> 空闲超时。细节见 `docs/status.md` §0 的 P40–P43 与 §8 变更日志。

**明确不做（连同理由）**

| 它的建议 | 为什么不做 |
|---|---|
| 多租户 / 按设备分权 | 与「单租户自用」的整体设计冲突（`clients` 无 tenant、ADR 多处在讲这个取舍）。真要做是换项目，不是加固 |
| Hub 侧再按 device 限并发 | 执行侧已限（`command-worker.js:72` `MAX_CONCURRENCY = 8`、`commands.concurrency`、同 workspace 串行，ADR-41）。再加一层只会让「pending 堆积但没人跑」更难排查 |
| 缩短 token 有效期 / 强制轮换 | 当前 token 是长期 Bearer、App 存在 `shared_preferences`，没有 refresh 机制。改造量 ≈ P41 的 5 倍，收益低于 P41（先把「进日志」这条堵掉） |
| 3.4 把 health 全关掉 | 只挪 `sseClients`，`ok` / `db.latencyMs` 要留着——`deploy/windows/verify-hub.ps1` 和 AGENTS.md §1 的开工自检都依赖它 |

## 6. 以后怎么用这类审计文档

1. **先核事实，再谈采纳**：任何「某某端点缺少校验」「某变量默认值危险」的断言，都必须能落到
   `文件:行号` 或一条可复现命令上；落不到就当「待验证的猜想」，不进待办。
2. **看前提是否成立**：同类漏洞（尤其 CVE）要核三件事 —— 影响的产品名、修复版本、凭据模型
   （cookie 还是 bearer）。凭据模型不同，攻击模型就不同，不能类比。
3. **宁可低估，不夸大**：把「可利用」写成 🔴 会让真正该修的项被稀释。本文把 Origin 从 🔴 降到低/中、
   把 XFF 从「条件写错」纠正为「取段错」，就是这个原因。
4. **改完要能验收**：每条加固都写「怎么证明生效」（伪造 XFF / 假 Origin / 连 9 条 SSE / 硬杀 bridge），
   否则下次没人敢动这段代码。


