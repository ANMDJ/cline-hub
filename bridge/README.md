# bridge · Windows 采集器 / 命令执行器

> 常驻在每台 Windows 上：增量读 Cline 的 `sessions.db` + `messages.json` 上报 Hub，
> 同时轮询 Hub 的待执行命令，交给 `cline` CLI 跑完再回写结果。
>
> 首次接入（含 Hub 建设备、config 字段、多台电脑）看
> [`../docs/new-device.md`](../docs/new-device.md)；本机实测事实看
> [`../docs/bridge-notes.md`](../docs/bridge-notes.md)。

## 运行

```powershell
cd bridge
copy config.example.json config.json   # 首次
npm run once                           # 只跑一轮，调试用
node src/index.js                      # 常驻（= npm start）
npm run health                         # 127.0.0.1:3210/health
```

没有第三方运行时依赖，不需要 `npm install`；要求 **Node ≥ 22.5**。

后台启动只用 PowerShell 的 `Start-Process`（不要用 Git Bash 的 `nohup node ... &`）：

```powershell
Start-Process -WindowStyle Hidden node -ArgumentList 'src/index.js' -WorkingDirectory $PWD
```

## 配置（`config.json`，已 gitignore）

| 字段 | 默认 | 说明 |
|---|---|---|
| `hubUrl` | 空 | Hub 根地址，不带末尾 `/` 与 `/api/v1` |
| `deviceId` | 主机名 | 必须与 Hub 上 `create-device --id` 一致 |
| `deviceToken` | 空 | `clh_...`，只在创建时打印一次 |
| `dataDir` | `%USERPROFILE%\.cline\data` | Cline 数据根目录 |
| `workspaceWhitelist` | `[]` | 采集与执行两侧都校验；空 = 不限制，建议填绝对路径 |
| `pollIntervalMs` | `5000` | 领取命令 / 常规重扫间隔 |
| `runningPollIntervalMs` | `3000` | 执行中会话的重扫间隔 |
| `maxTextChars` | `20000` | 单条消息上限（超出截断并标 `truncated`） |
| `commands.enabled` | `false` | 远程命令总开关 |
| `commands.runner` | `shell`（示例为 `cline`） | `cline` = 交给 CLI 开新会话 |
| `commands.allowModes` | `["plan","act"]`（示例只留 plan） | 不在列表里的模式直接 `failed` |
| `commands.defaultWorkspace` | 空 | 命令没带 workspace 时的兜底目录，必须存在 |
| `commands.cline.bin` | 空（用 PATH） | Windows 上填 `cline.cmd` 绝对路径 |
| `commands.cline.provider` / `model` | 空 | 无头执行必须显式给 |
| `commands.cline.resume` | `true`（示例为 `false`） | 无头进程接不上 `--id` 续会话，保持 false |
| `commands.leaseHeartbeatMs` | `30000` | 租约心跳间隔（P42）：本机还拿着命令时周期 `POST /commands/:id/heartbeat`，空闲不发 |

## 租约心跳（P42）

Hub 给每条被认领的命令记一个租约（默认 120 秒）。bridge 在「本机还拿着命令」时
（跑着的 + 占着槽位的 + 排队等槽位的）每 `commands.leaseHeartbeatMs`（默认 30 秒）续一次：

```
POST /api/v1/commands/<id>/heartbeat   {}
```

- 只写 `lease_expires_at` 一列，**不改状态、不推 SSE**（不会把手机上的列表刷来刷去）；
- 单条失败只记 `command heartbeat failed` 日志，下一轮自动重试；
- 心跳断了、租约过期时由 Hub 收成 `failed: orphaned`（`cancelling` 收成 `cancelled`），
  与本机的 `npm run reconcile`（看得到进程）形成两道兜底。


## 附件（手机发来的文件 / 图片，P38）

命令可以带一个附件（`command.attachment`，内容在 Hub 上）。bridge 的处理顺序：

1. 领取到命令后先 `GET /api/v1/attachments/<id>`（device token，只能取自己那台设备的）；
2. 落盘到 `%TEMP%\cline-hub-cmd\incoming\<commandId>-<原文件名>`；
3. 把「用户那句话 + 绝对路径」拼成 prompt 再交给 `cline` / shell：

```
把这份周报里的错别字改掉

[附件] 手机端发来的文件已保存到这台电脑上：
  路径：C:\Users\alice\AppData\Local\Temp\cline-hub-cmd\incoming\cmd_9f2c-周报.docx
  原名：周报.docx
  类型：application/…（20.0 KB）
请先读取这个文件，再按上面的要求处理。
```

- 用户没写说明时，最后一句换成「请先读取这个文件，简要说明它是什么内容；先不要修改任何文件」。
- 下载失败 / 空文件 / 超过 16 MB → 命令直接 `failed`，`errorText` 以「附件下载失败：」开头；
  不带着「找不到文件」的 prompt 继续跑。
- 临时目录不自动清理：文件很小，且 `%TEMP%` 由系统回收；要立刻清就删 `cline-hub-cmd\incoming`。
- 上限是 `bridge/src/attachment.js` 的 `MAX_ATTACHMENT_BYTES`（16 MB，比 Hub 默认的 8 MB 宽一档）。


| 命令 | 作用 |
|---|---|
| `npm run ps` | 本机登记：`commandId → pid`，pid + 启动时间双校验；`--kill <id>` / `--clean` |
| `npm run stop -- --reason "..."` | 优雅停：先回写执行中的命令，再杀进程树 |
| `npm run restart -- --reason "..."` | 停 + detached 重启 |
| `npm run restart:idle -- --reason "..."` | 等执行中的命令跑完再重启（在命令里发起重启时用） |
| `npm run reconcile [-- --dry-run]` | 把「Hub 上 running 但本机没进程」的命令回写 `failed: orphaned` |
| `npm run resend -- --missing-project [--dry-run]` | 手工重发旧会话 / 补项目名 / 补全文 |
| `npm run check:whitelist` | 校验 `workspaceWhitelist` 配置 |

## 目录

```
src/index.js           启动、扫描、上报、hook server（/hook、/admin/stop）
src/config.js          配置加载与默认值
src/record.js          会话快照 / 消息拍平 / 指纹（采集与 resend 共用）
src/extract.js         从 sessions.db / messages.json 提取
src/cline-json.js      解析 cline --json 的结构化输出
src/command-worker.js  领取、并发池、spawn、取消、对账
src/command-registry.js 本机 running 登记（%TEMP%\cline-hub-cmd\running）
src/process-info.js    pid + 启动时间查询
scripts/*.mjs          ps / stop / restart / reconcile / resend / 白名单检查
test/*.test.js         node --test
```

## 验证

```powershell
cd bridge
node --test            # 单元 + 假 CLI 端到端
npm run check:whitelist
npm run health
```

全链路（Windows）用 [`../deploy/windows/verify-hub.ps1`](../deploy/windows/verify-hub.ps1)。

## 常见问题

| 现象 | 处理 |
|---|---|
| 命令一直 `pending` | `commands.enabled` 是否为 true；bridge 是否在轮询 |
| `workspace not allowed` | 把目录加进 `workspaceWhitelist`，或清空该数组 |
| 命令卡 `running` | `npm run ps` 看进程；bridge 被硬杀过就 `npm run reconcile` |
| 会话不上报 | `dataDir` 对不对；Cline 有没有产生 `sessions.db`；看 `logs/bridge.log` |
| 想停但怕卡任务 | 只用 `npm run stop -- --reason "..."`，不要 `Stop-Process` |

主动中断要记 [`../docs/interruptions.md`](../docs/interruptions.md)。
