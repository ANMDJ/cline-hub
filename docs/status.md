# 现状与待办（status）

> 每次开工先读 §0；动手前核对 §1 的实测值。最后更新：**2026-11-02（+08）**。

## 0. 现在要做什么

按顺序执行，做完一项就把勾打上、并在 §8 记一行。

| 阶段 | 内容 | 状态 |
|---|---|---|
| P0 | 补文档骨架（本文件、`docs/README.md`、README 入口） | ✅ 已完成 |
| P1 | **Bug：手机发 ACT，CLI 实际跑成 PLAN**（bridge 注入 `CLINE_GLOBAL_SETTINGS_PATH` 钉死模式 + 跑完校验 + 详情页模式栏继承） | ✅ 已端到端验证（探针会话 `1793586094677_7y65n`） |
| P2 | **Bug：PLAN/ACT 选中态配色看不清**（`modeSegmentStyle()` 统一背景/边框/文字） | ✅ 代码完成，待真机核对比度 |
| P3 | **Bug：会话内容展示不全**（方案 B：上限 2000→20000 + `truncated` + 版本 2 触发有限回填 + 折叠 + 全文页） | ✅ 代码完成，**待部署**（migration 004） |
| P4 | **Bug：会话内容没有复制**（气泡复制 / 整段复制 / 全文页复制） | ✅ 代码完成 |
| P5 | 列表预览纯文本化（去 Markdown/ANSI，治「列表乱码」） | ⏳ 未开始 |
| P6 | bridge 用 `cline --json` 取结构化结果（会话 ID / 最终文本） | ⏳ 未开始 |
| P7 | 命令并发池 + 卡死命令回收 | ⏳ 未开始 |
| P8 | 详情页 Markdown 渲染（`flutter_markdown_plus`） | ⏳ 未开始 |
| P9 | 「选择题」`ask_question` 在 App 里可点选 | ✅ 代码完成，**待部署**（migration 005） |
| P10 | App 内更新：版本 1.1.0 / 更新日志 / 检查更新 / 发版脚本 | 🟡 代码完成；APK 需 Android SDK + JDK 17（本机缺） |

### 上线前必须做（代码已改，服务器还没吃）

1. `cd server && npm run migrate`（新增 `004_message_truncated`、`005_message_options`）；
2. 重启 Hub（`systemctl restart cline-hub`）才会暴露 `/api/v1/app/latest` 与新字段；
3. 重启 Windows bridge：会触发 `transcript version changed, re-arming backfill`，随后 2 个会话/tick 补历史；
4. App 重新打包（`1.1.0+2`）后才带新的详情页/复制/选项更新 UI。

规则：**P3 方案已定为 B** —— 提升限额后，只回填最近 60 个会话（`TRANSCRIPT_BACKFILL_LIMIT`），每 tick 2 个，按字节切批。

## 1. 基线快照（2026-11-02 09:15 实测）

| 项 | 实测 |
|---|---|
| 分支 / HEAD | `master` @ `a20abe1` |
| Hub | `{"ok":true,...,"db":{"ok":true,"latencyMs":0},"sseClients":1}` |
| bridge | `{"ok":true,"service":"cline-bridge"}`（手动启动，未开机自启） |
| 线上入口 | `https://hub.littlewish.top:8443` |
| Cline CLI | `3.0.74`（已是最新，`--json` 可用，**没有 `--act`**） |
| Flutter / Dart | `3.47.5` / `13.4` |
| Android 工具链 | ❌ 无 SDK（`ANDROID_HOME` 空、无 `sdkmanager`/`gradle`）、JDK 仅 1.8 |
| 已跟踪会话 | 89 个（80 个有 `messages.json`），14,755 条已上报消息 |

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
**P1**：P3–P10（见 §0）；`act` 并发同工作区互相覆盖的风险（默认 `concurrency: 1`）。
**P2**：App 无 SSE 的 Web 预览降级体验；命令取消（目前只能等超时）。
**P3**：多设备推送、审计视图细化。

## 5. 已知坑（别重复踩）

1. **CLI 没有 `--act`**：`modeExplicitlySet` 只认 `--plan/--yolo/--zen`，否则模式取 `settings/global-settings.json` 的 `planActMode` → 手机发 act 也会跑成 plan。修法见 `command-worker.js` 的 `clineModeEnv()`。
2. **`--id` 续会话要 TTY**：无头只能 `-c <workspace>` 新开会话。
3. **`spawn` 必须 `stdio: 'ignore'`**：否则 cline 等 stdin，命令永远「执行中」。
4. **prompt 单个词会被当子命令**：不带空格时补尾随空格（`a20abe1`）。
5. **SSE 反代必须 `flush_interval -1`**，否则事件被 Caddy 缓冲。
6. **本机打不了 APK**：缺 Android SDK + JDK 17；`app/build` 里的产物来自 `flutter test`/Web 预览，不是 APK。
7. **会话消息在源头被截断**：`extract.js` 的 `clip()`（`maxTextChars`）与 `maxResultChars`，不是 UI 折叠问题。
8. **`TRANSCRIPT_VERSION` 提升只影响被扫描到的会话**：静止老会话不会自动重发，需重开回填队列（§0 P3）。

## 6. 自检命令

```powershell
cd bridge; node --test; node scripts/check-workspace-whitelist.mjs
cd server; npm run migrate; node scripts/check-preview.mjs
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
