# Cline Console

自建「Cline 控制台」：Windows 端采集 VS Code Cline 插件 + CLI 的会话结果与命令，
经 Hub 落库并推送到 Android，同时支持从手机下发远程命令回 Windows 执行。

## 组成

| 模块 | 位置 | 说明 |
|---|---|---|
| Hooks | `hooks/` → `%USERPROFILE%\Documents\Cline\Hooks\` | Cline 全局钩子，任务结束/失败/中断时推送 |
| Bridge | `bridge/` | Windows 常驻进程：收 Hook、增量读 `sessions.db`、上报 Hub、执行远程命令 |
| Hub | `server/` | Ubuntu 上的接收端：REST + SSE + Postgres（本机已联调通过） |
| App | `app/`（M2） | Flutter Android 客户端 |

## 数据流

1. **实时**：Cline hook → `_notify.ps1` → ntfy（手机立刻收到）+ `127.0.0.1:3210/hook`（bridge 入库）
2. **回溯**：bridge 轮询 `%USERPROFILE%\.cline\data\db\sessions.db`（`updated_at` 水位线）
   → 读同目录 `messages.json` → 只抽「结果文本 + run_commands/execute_command」→ 上报 Hub
3. **远程命令**：App → Hub `POST /api/v1/commands` → bridge 轮询 `/api/v1/commands/pending`
   → 按 `config.commands.template` 本地执行（默认把 prompt 当 PowerShell 脚本；也可改成 `cline --yolo "{prompt}"`）
   → `PATCH /api/v1/commands/:id` 回写 running/done/failed + 输出
4. **下行通知**：手机保持一条 `GET /api/v1/events`（SSE），新会话/新命令即时到达；断线时退化为轮询


## 端口

| 端口 | 归属 | 绑定 |
|---|---|---|
| 3210 | bridge hook server | 127.0.0.1 |
| 3100 | Hub | 127.0.0.1（Caddy 反代 hub.littlewish.top） |
| 3000 | kids_points API | 127.0.0.1（Caddy 反代 /api） |
| 2586 | ntfy | 127.0.0.1（Caddy 反代 ntfy.littlewish.top） |

## 里程碑

| 阶段 | 内容 | 状态 |
|---|---|---|
| M0 | Hook 脚本 + ntfy 通知 | ✅ 完成 |
| M1 | bridge 采集器 + Hub 服务 + 部署 | ✅ 完成（`https://hub.littlewish.top`，smoke 20/20） |
| M2a | 远程命令通道（bridge 执行器） | ✅ 完成（App→Hub→bridge→PowerShell→回写，实测 6s 闭环） |
| M2b | Flutter App（会话列表/命令执行） | 待开始 |


## 快速开始（本机）

```powershell
# 1. 配置推送（已生成默认值）
notepad $env:USERPROFILE\.cline\notify.config.json

# 2. 起 bridge
cd C:\Users\alice\projects\cline-hub\bridge
node src/index.js

# 3. 自检
curl http://127.0.0.1:3210/health
```

### Hub 本机联调

```powershell
cd C:\Users\alice\projects\cline-hub\server
copy .env.example .env      # 填 HUB_DATABASE_URL / HUB_ADMIN_TOKEN
npm install
npm run migrate
npm run create-device -- --id localone --name "LocalOne-Windows"    # 打印一次 token
npm run create-device -- --id phone --role app --name "Pixel-8"

# 后台常驻：不要用 bash 的 `nohup ... &`（会把终端 shell 一起带走）
Start-Process -WindowStyle Hidden node -ArgumentList 'src/index.js' -WorkingDirectory $PWD
curl http://127.0.0.1:3100/api/v1/health
```

把打印出的 token 分别写进 `bridge/config.json`（`hubUrl` / `deviceId` / `deviceToken`）和 App 设置页。
接口约定见 [`docs/api.md`](docs/api.md)，上线步骤见 [`deploy/README.md`](deploy/README.md)。

## 远程命令（bridge 执行器）

bridge 每 `pollIntervalMs` 轮询 `/api/v1/commands/pending`（服务端 `FOR UPDATE SKIP LOCKED` 认领，多开也不会重复执行），
拿到任务后 → `PATCH running` → 本地跑 → `PATCH done/failed` 回写输出。

默认**关闭**，在 `bridge/config.json` 里打开：

```json
"commands": {
  "enabled": true,
  "template": "{prompt}",
  "shell": "powershell",
  "allowModes": ["plan", "act"],
  "defaultWorkspace": "C:\\Users\\alice\\projects",
  "timeoutMs": 600000,
  "batchSize": 3
}
```

| 字段 | 说明 |
|---|---|
| `enabled` | 总开关；false 时命令一直留在 `pending`，不会被执行 |
| `template` | 脚本模板，支持 `{prompt}` / `{mode}` / `{workspace}`；默认 `{prompt}`＝「prompt 就是脚本」 |
| `shell` | `powershell`（默认）/ `cmd` / `bash`；脚本先落成临时文件再执行，绕开引号与换行转义 |
| `allowModes` | 模式白名单，`yolo` 默认不在内；被拒命令直接 `failed` 并写明原因 |
| `defaultWorkspace` | 命令未带 `workspace`（或路径不存在）时的默认工作目录 |
| `timeoutMs` | 超时强杀进程树（`taskkill /t /f`），回写 `timeout after ...` |
| `batchSize` | 单轮最多取几条，串行执行 |

想接 Cline CLI：把 `template` 改成 `"cline --yolo \"{prompt}\""`（本机需先装 `cline`）。

### 常驻与开机自启

```powershell
# 起（别用 bash 的 nohup，会把终端 shell 一起带走）
Start-Process -WindowStyle Hidden node -ArgumentList 'src/index.js' `
  -WorkingDirectory 'C:\Users\alice\projects\cline-hub\bridge'
```

开机自启用**启动文件夹**里的 VBS（不需要管理员权限）：

```vbscript
' %APPDATA%\Microsoft\Windows\Start Menu\Programs\StartUp\ClineBridge.vbs
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = "C:\Users\alice\projects\cline-hub\bridge"
sh.Run "node ""C:\Users\alice\projects\cline-hub\bridge\src\index.js""", 0, False
```

> 已在本机创建好该文件。想换成计划任务得用**管理员** PowerShell：
> `schtasks /create /tn ClineBridge /sc onlogon /rl limited /f /tr "node C:\Users\alice\projects\cline-hub\bridge\src\index.js"`
> （普通权限会 `ERROR: Access is denied.`）

## 约定

- 仓库内**不出现任何真实口令/token**；`bridge/config.json` 与 `.env` 均被 gitignore。
- `.ps1` 文件保持 **ASCII-only**（Windows PowerShell 5.1 会把无 BOM 的 UTF-8 当 ANSI 读，中文会乱码）。
- Hook 脚本**永不阻塞**：任何异常都 `exit 0`，失败只写 `%USERPROFILE%\.cline\notify.log`。
