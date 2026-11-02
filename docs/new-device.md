# 接入第二台电脑（新 bridge）

> **目标**：新开一台 Windows 电脑，让它上面的 Cline 会话出现在手机里，并且能从手机向它下发命令。
> 预计 15 分钟，**不用改 Hub 代码，也不用动第一台电脑**。
>
> 已经部署好 Hub、但还没在手机上跑通？先看 [`self-host.md`](self-host.md)。

## 0. 一条命令看懂要做什么

```
Hub 上建一个 device client（拿到一次性 token）
  → 新电脑放 bridge + 填 config.json
  → 起 bridge，会话开始上报
  → App「设置 → 已接入设备」看到它，设为默认
  → 发一条 plan 命令验证闭环
```

设备之间是隔离的：每台电脑一个 `deviceId` + 独立 token，读接口只能读自己的数据（ADR-43）。

---

## 1. 新电脑的前置检查

打开 **PowerShell**：

```powershell
node -v
where.exe cline
Test-Path "$env:USERPROFILE\.cline\data\db\sessions.db"
```

| 结果 | 含义 / 下一步 |
|---|---|
| `v22.x` 或更高 | ✅ bridge 要求 Node ≥ 22.5 |
| 找不到 node | 装 Node 22 LTS，重开终端 |
| `where.exe` 找不到 cline | 先在 Cline 里装并登录 **CLI**，直到 `cline --version` 能跑 |
| `sessions.db` 不存在 | Cline 还没在这台机器上跑过会话；先开一次会话再继续 |

> 只要采集（不上报命令），不装 CLI 也能跑；要远程执行命令就必须有可用的 `cline`。

---

## 2. 在 Hub 上创建设备（只做一次）

`deviceId` 自己起名，规则：2–32 位，小写字母 / 数字 / `.` `_` `-`，不能重名。

### 方式 A：本机仓库（能连到 Hub 的数据库时）

```powershell
cd <仓库>\server
npm run create-device -- --id office-pc --name "Office-PC"
```

### 方式 B：服务器上的 Docker

```bash
sudo docker compose exec hub npm run create-device -- --id office-pc --name "Office-PC"
```

### 方式 C：Admin HTTP 接口

```powershell
$admin = '<HUB_ADMIN_TOKEN>'
$body = '{"id":"office-pc","name":"Office-PC","role":"device"}'
Invoke-RestMethod -Method Post `
  -Uri 'https://<你的 Hub>/api/v1/clients' `
  -Headers @{ Authorization = "Bearer $admin" } `
  -ContentType 'application/json' -Body $body
```

三种方式写的是同一张 `clients` 表。**token 只在创建时打印一次**（库里只存 sha256）：
立刻存进密码管理器，不要贴进聊天/截图/仓库。

> 建错了想重来：把同一个 `--id` 再执行一次会**轮换 token**（旧 token 立即失效）。
> 删除用 `DELETE /api/v1/clients/<id>?confirm=1`，会级联删掉该设备的会话 / 命令 / hook。

---

## 3. 把 bridge 放到新电脑

```powershell
git clone <仓库地址> C:\cline-hub
cd C:\cline-hub\bridge
copy config.example.json config.json
```

也可以直接拷贝整个仓库目录，但**不要拷** `config.json`、`.secrets/`、`logs/`、`state.json`、
`outbox.json`（那是第一台机器的状态）。

bridge **没有第三方依赖**，不需要 `npm install`。

---

## 4. 填 `bridge/config.json`

只改下面这些，其余保持默认：

```json
{
  "hubUrl": "https://hub.example.com",
  "deviceId": "office-pc",
  "deviceToken": "clh_粘贴上一步的 token",
  "workspaceWhitelist": ["C:\\Users\\you\\projects"],
  "dataDir": "",
  "commands": {
    "enabled": false,
    "runner": "cline",
    "allowModes": ["plan"],
    "defaultWorkspace": "C:\\Users\\you\\projects",
    "cline": {
      "bin": "C:\\Users\\you\\AppData\\Local\\...\\cline.cmd",
      "provider": "你的 provider",
      "model": "你的 model",
      "json": true,
      "resume": false
    }
  }
}
```

| 字段 | 怎么填 | 坑 |
|---|---|---|
| `hubUrl` | 不带末尾 `/`；能 HTTPS 就 HTTPS | 写成 `.../api/v1` 会 404 |
| `deviceId` | 必须和上一步创建的一致 | 手滑写错 → `unknown_device` / 收不到命令 |
| `deviceToken` | 一次性 token 原样粘贴 | 复制时少了 `clh_` 会 401 |
| `dataDir` | 留空 = `%USERPROFILE%\.cline\data` | Cline 数据在别处才需要改 |
| `workspaceWhitelist` | **建议非空**，填绝对路径 | 空数组 = 不限制；非空时采集和执行两侧都会校验 |
| `commands.enabled` | 先 `false`，跑通采集后再改 `true` | 关着时命令一直 `pending`，不会执行 |
| `commands.allowModes` | 先只留 `"plan"` | 手机发 `act` 但不在列表 → `failed` |
| `commands.defaultWorkspace` | 必须真实存在的目录 | 不存在且命令没带 workspace → 直接失败 |
| `cline.bin` | `where.exe cline` 的完整路径（`cline.cmd`） | Node 直接 spawn `.cmd` 会 `ENOENT`，bridge 已用 shell 包一层 |
| `cline.provider` / `model` | 本机 `cline` 能用的组合 | 留空时无头执行会失败；bridge 必须显式传 `-P` / `-m` |
| `cline.resume` | 保持 `false` | CLI 的 `--id` 续会话要 TTY，无头进程接不上（ADR-21/24/27） |

填完先做静态检查：

```powershell
cd C:\cline-hub\bridge
npm run check:whitelist
```

---

## 5. 起 bridge

```powershell
cd C:\cline-hub\bridge

# 先只跑一轮，确认能连上 Hub（不会常驻）
npm run once

# 常驻（另开一个 PowerShell 窗口）
node src/index.js
```

成功的样子：

```powershell
npm run health
# {"ok":true,"service":"cline-bridge",...}
```

日志在 `bridge/logs/bridge.log`。此时第一台电脑不需要做任何事。

> 后台启动只用 `Start-Process`，不要用 Git Bash 的 `nohup node ... &`
> （会把终端 shell 一起带走）：
>
> ```powershell
> Start-Process -WindowStyle Hidden node -ArgumentList 'src/index.js' `
>   -WorkingDirectory 'C:\cline-hub\bridge'
> ```

---

## 6. 在手机上确认

1. 打开 App → **设置 → 已接入设备 → 刷新**：应出现 `office-pc`，前 2 分钟内有上报就是「在线」。
2. 点 **设为默认**（或回到「默认执行设备」手动填 `office-pc` 并保存）。
3. 会话页应开始出现该设备的会话；设备 chip 只在 ≥2 台设备时出现。
4. 在命令页发一条 `plan`：`在 office-pc 上，列出当前工作目录的文件`，
   选择工作目录后发送，观察 `pending → delivered → running → done`。

命令卡片上的「项目目录 · 设备 · 相对时间 · 耗时」能直接看出是哪台机器在跑。

---

## 7. 可选：开机自启

把 [`deploy/windows/ClineBridge.vbs`](../deploy/windows/ClineBridge.vbs) 里的两处路径改成新电脑的
`C:\cline-hub\bridge`，然后复制到：

```
%APPDATA%\Microsoft\Windows\Start Menu\Programs\StartUp\ClineBridge.vbs
```

它用 `WScript.Shell` 无窗口启动，不需要管理员权限。
要停掉自启：把文件删掉或改名（例如 `.disabled`）。

---

## 8. 可选：任务完成通知（hooks）

`hooks/` 是 Cline 全局钩子脚本，任务结束 / 失败 / 中断时推 ntfy + 本机 bridge。
复制到 `%USERPROFILE%\Documents\Cline\Hooks\`（`.ps1` 必须保持 **ASCII-only**，否则
Windows PowerShell 5.1 会乱码）。

但 **Cline 4.1.26 起全局 hooks 改成工作区级 `.clinerules/hooks`**，老的外挂 hook 可能不再触发。
bridge 会自己观察 `sessions.db` 的状态跃迁（`running → completed/failed/cancelled`），
补发 `session_done` / `session_failed` / `session_cancelled` 事件——所以**不装 hooks 也有完成通知**。
详见 [`api.md`](api.md)「完成通知从哪来」。

---

## 9. 多台电脑的边界

| 场景 | 做法 |
|---|---|
| 同一台电脑两份 Cline 数据 | 两个 bridge、两个 `dataDir`、两个 `deviceId`；别共用 `state.json` |
| 同一个 workspace 在多台设备 | 各自上报，会话按 `(deviceId, sessionId)` 分开；App 里用设备 chip 区分 |
| 远程命令发错机器 | 下发面板里明确选设备；默认设备在设置页 |
| 一台设备 token 泄露 | 只轮换那一台的 token：重新 `create-device --id <同一 id>`，其它设备不受影响 |
| 想停掉某台电脑的远程执行 | 该电脑 `commands.enabled=false`，采集继续，命令不再被领取 |

---

## 10. 排障速查

| 现象 | 先查 |
|---|---|
| App 设备列表里没有新设备 | bridge 是否在跑；`hubUrl` / token 是否正确；`npm run health` |
| 有设备但会话不出现 | `dataDir` 是否指向 Cline 数据；`workspaceWhitelist` 是否把该目录排除了；看 `bridge/logs/bridge.log` |
| 设备一直「离线」 | bridge 进程退出 / 网络不通；`last_seen_at` 只在请求时更新 |
| 命令一直 `pending` | 该设备 `commands.enabled=false`，或 bridge 没轮询 |
| `failed: workspace not allowed` | 手机选的工作目录不在 `workspaceWhitelist`，`npm run check:whitelist` |
| `failed: mode "act" is not allowed` | `commands.allowModes` 没开 act |
| 命令卡在 `running` | 进程还在（`npm run ps`）；bridge 被硬杀过则 `npm run reconcile` |
| `401 invalid_token` | token 被轮换 / 粘贴错；重新建 client 并只改这一台的 config |
| Hub 返回 `403 device_mismatch` | 用 device token 读了别的设备；检查 config 里的 `deviceId` |

更细的本机事实见 [`bridge-notes.md`](bridge-notes.md)，接口字段见 [`api.md`](api.md)。
