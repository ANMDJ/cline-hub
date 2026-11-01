# Bridge 实测记录（2026-10-31）

本文件记录**在本机实测得到**的事实，不是推测。后续改代码前先看这里。

## 1. Cline 数据位置

| 项 | 实测值 |
|---|---|
| 数据库 | `%USERPROFILE%\.cline\data\db\sessions.db`（WAL 模式，有 `-wal` / `-shm`） |
| 会话消息 | `%USERPROFILE%\.cline\data\sessions\<session_id>\<session_id>.messages.json` |
| 全局 Hook 目录 | `%USERPROFILE%\Documents\Cline\Hooks\`（Windows 只认 `.ps1`） |
| 本次实测版本 | Cline 插件 4.1.26；CLI `cline@3.0.74` |

`sessions` 表字段（`sqlite_master` 原样读出）：

```
session_id, source, pid, started_at, ended_at, exit_code, status, status_lock,
interactive, provider, model, cwd, workspace_root, team_name, enable_tools,
enable_spawn, enable_teams, parent_session_id, parent_agent_id, agent_id,
conversation_id, is_subagent, prompt, metadata_json, transcript_path,
hook_path, messages_path, updated_at
```

`status` 实测出现值：`running` / `completed` / `failed` / `cancelled`。
`transcript_path` 在本机为空字符串，**只能依赖 `messages_path`**。

## 2. messages.json 结构

```json
{
  "version": "...",
  "updated_at": "...",
  "agent": "...",
  "sessionId": "1793406873889_kz6g7",
  "origin": "...",
  "system_prompt": "...",
  "messages": [
    { "id": "msg_x", "role": "assistant|user", "ts": 1793428260844,
      "modelInfo": {}, "metrics": {},
      "content": [ { "type": "text|thinking|tool_use|tool_result", ... } ] }
  ]
}
```

content 块实测分布（一个 60 条消息的会话）：
`assistant:thinking 23 / assistant:text 22 / assistant:tool_use 32 / user:text 4 / user:tool_result 32`

`tool_use` 形状：

```json
{"type":"tool_use","id":"call_00_...","name":"run_commands",
 "input":{"commands":["dir /b ...","node -v && npm -v"]}}
```

`tool_result` 挂在 **user** 消息里，bridge 不采集（体积大、手机端无用）。

## 3. 提取规则（`bridge/src/extract.js`）

- 结果文本：**最后一条** assistant `text` 块（覆盖式取最后）。
- 命令：仅 `run_commands`（`input.commands`，按行拼接）与 `execute_command`（`input.command`）。
- 丢弃：`thinking`（只统计字符数）、`tool_result`、文件正文。
- 截断：结果 4000 字符（`maxResultChars`），命令 300 条。
- 用户输入：最后一条 user `text`，并剥掉 `<user_input ...>` 包裹标签。

实测：20 条会话 → `outbox.json` 约 1.2 MB（含命令全文），单条最大 300 条命令。

## 4. Hook 链路（已验证）

```
Cline --stdin(UTF-8)--> agent_end.ps1 --> _notify.ps1
                                        ├─ ntfy JSON publish  (https://ntfy.sh, 8s 超时)
                                        └─ POST 127.0.0.1:3210/hook (2s 超时)
```

实测日志：

```
2026-10-31 16:36:05 [agent_end]   ntfy ok -> https://ntfy.sh / cline-lw-7f3a9c2e5b1d4a86
2026-10-31 16:39:25 [agent_end]   bridge ok
2026-10-31 16:36:20 [agent_error] ntfy ok
2026-10-31 16:36:27 [agent_abort] ntfy ok
2026-10-31 16:36:32 [agent_end]   stdin is not valid json, skipped
```

topic 上收到的实际消息（中文无乱码）：

```json
{"title":"Cline DONE - cline-hub",
 "message":"M0 通知链路测试：中文编码 ✅ 通过\n\ncline-hub / test-m0-001",
 "priority":3,"tags":["white_check_mark"]}
```

### 两个必须记住的坑

1. **stdin 必须显式按 UTF-8 读**：`StreamReader([Console]::OpenStandardInput(), [Text.Encoding]::UTF8)`。
   直接用 `$input` / `Console.In` 在中文 Windows 上会按 GBK 解码成乱码。
2. **HTTP header 不放中文**：ntfy 改用 **JSON publish**（`POST /` + `{topic,title,message}`），
   避免 `Title` 头被 Latin-1 编码。
3. `.ps1` 保持 **ASCII-only**：Windows PowerShell 5.1 把无 BOM 的 UTF-8 当 ANSI 解码。

## 5. bridge 运行方式

```bash
cd C:\Users\alice\.cline\data\workspaces\chat\cline-hub\bridge
node src/index.js          # 常驻
node src/index.js --once   # 只跑一轮（调试）
curl http://127.0.0.1:3210/health
```

停止（精确匹配，不会误杀 Cline 自己的 node 进程）：

```powershell
Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
  Where-Object { $_.CommandLine -like '*src/index.js*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

开机自启（登录时）：

```powershell
schtasks /create /tn "ClineBridge" ^
  /tr "node C:\Users\alice\.cline\data\workspaces\chat\cline-hub\bridge\src\index.js" ^
  /sc onlogon /rl highest /f
```

> 若 `node` 不在系统 PATH（nvm 装的常是用户级），把 `/tr` 换成绝对路径：
> `C:\Users\alice\AppData\Local\Author Software\nvm\installs\v26.10.0\node.exe`

## 6. 当前状态

| 项 | 值 |
|---|---|
| `bridge/config.json` | 已生成，`hubUrl` 为空（先本地排队） |
| `outbox.json` | 已累积历史会话，`hubUrl` 配好后自动补发 |
| 水位线 | `bridge/state.json` 的 `lastUpdatedAt`，只前进不后退 |
| 去重 | `state.sentSessions`（上限 2000） |

## 7. 2026-11-01 安全排查记录（"是不是有人在控制我的电脑"）

### 现象

本机 PowerShell 窗口里出现「自动输入内容 + 下载进度（31M / 30M 之类）」。

### 排查结论：**没有入侵**

| 检查项 | 实测结果 |
|---|---|
| 远控软件进程（AnyDesk/ToDesk/向日葵/RustDesk/VNC/ScreenConnect/Splashtop/ngrok/frpc） | 0 个 |
| RDP 服务端 | `fDenyTSConnections=1`、`TermService` 已停、3389 无监听 |
| 入站监听端口 | 只有 `:::135`(RPC) 与 `::1:9100`(dart，仅回环) |
| 启动项 / 启动文件夹 | `ctfmon`、Edge AutoLaunch ×3、`360Safetray`，**外加本项目的 `ClineBridge.vbs`** |
| WMI 持久化 `root\subscription` | 只有系统自带 `SCM Event Log Filter` |
| Defender | 实时防护/篡改防护开，无任何威胁记录 |
| PowerShell 4104 脚本块日志 | 6 小时内全部来自本机 Cline 会话执行的诊断命令 |
| 本地账号 | 只有 `alice`；`Administrator` 禁用；⚠️ `Guest` 处于启用态（建议关） |

### 「自动打字」的真正来源

```
18:10:20  explorer.exe → WindowsTerminal.exe（窗口标题 "> 继续"）
18:10:29  └─ powershell.exe(22124) → node .../cline/bin/cline   ← Cline CLI
18:13:47+ cline.exe 拉起 powershell -NoProfile -NonInteractive -Command ...   ← 工具调用
```

**反证**：`%APPDATA%\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt` 的
**LastWriteTime 停在 15:18:23**。真有人在窗口里敲字，PSReadLine 会把每条命令追加进去；
它没变，说明**没有真实键盘输入** —— 看到的是 Cline CLI 把工具调用里的命令回显到终端，
后面跟的 `31M / 30M` 是命令自身的 stdout（`npm ci` / `docker build` / `curl` 这类进度条）。

> 记住这条判据：**「窗口里有字在动」≠「有人在敲」**。PSReadLine 的时间戳是最好用的证据之一。

### 唯一真实的外部入口：本项目 bridge

- 启动文件夹 `ClineBridge.vbs` → `node bridge/src/index.js`，`bridge/logs/bridge.log` 有
  `session queued` / `command finished {"runner":"cline","status":"failed"}` 等实跑记录；
- `config.json` 里 `hubUrl=http://82.157.153.22/_h/<前缀>`（明文）+ `commands.enabled=true`
  + `allowModes=[plan,act]` + `workspaceWhitelist=[]`；
- 即 **App → Hub → bridge → 本机 PowerShell / cline CLI** 这条链是通的，且 act 模式无人值守。

### 处置（对应 ADR-19）

1. `commands.enabled` → `false`；`allowModes` → `["plan"]`；
2. `workspaceWhitelist` → 两个绝对路径，并且**执行侧**新增校验（`isWorkspaceAllowed`）；
3. 启动文件夹 VBS 改名 `ClineBridge.vbs.disabled`（不再自启）；
4. 自检：`cd bridge && npm run check:whitelist`（10 条用例）＋ `node --check src/*.js`；
5. 两件需提权的事已用 `Desktop\security-check-20261101\admin-run.bat`（自提权 + UAC）办完：
   `Guest` 已禁用、`Hermes_Gateway` 计划任务已删除；复核用 `admin-run.bat /check`。
   ⚠️ 提权判断别用 `net session` —— 本机非管理员会话也返回 0，会静默跳过 UAC；
   要用 `IsInRole([WindowsBuiltInRole]::Administrator)`（`admin-run.bat` 里就是这么写的）。
   `.ps1` 右键菜单没有「以管理员身份运行」（只有 `.exe`/`.bat` 有），所以必须走 `.bat` 入口。

### 遗留待确认（已全部查明）

- ~~RDP「客户端」痕迹~~ → **是 WSLg，不是远程桌面。** 证据链：
  1. `C:\Program Files\WSL\msrdc.exe`（签名 Valid / CN=Microsoft Corporation），同目录有
     `wslg.exe`、`wslg.rdp`、`rdclientax.dll`、`rdpnanoTransport.dll`；
  2. `wslg.rdp` 内容：`hvsocketenabled:i:1` / `remoteapplicationmode:i:1` /
     `enablecredsspsupport:i:0` / `authentication level:i:0` → 走本机 hvsocket、RemoteApp 模式、无认证无 SSL；
  3. `Microsoft-Windows-TerminalServices-RDPClient/Operational` 里 **211 次连接的 "Server Name" 全是 GUID**
     （150 个去重目标，0 个主机名/IP），并伴随 `Server supports SSL = not supported`、空用户名；
  4. ETL 里的 `msrdc.exe` / `RdClient.SessionHost\exe\msrdc` / `MSRDCRecoveryManager` 都来自官方构建路径
     `C:\__w\1\s\RdClient\...`；
  5. 时间跨度 2026-04-13 起共 1874 条，与「开 Linux GUI 应用」的时段吻合。

  → 结论：WSL 的 Linux GUI（WSLg）用本机 RDP 客户端把图形界面投到 Windows，**不出网**。
  `HKCU\...\Terminal Server Client\Default\MRU0..9` 的 GUID 与 `LocalDevices` 的磁盘重定向项同样是 WSLg 写的。
  `%TEMP%\DiagOutputDir\RdClientAutoTrace\` 里的 ETL 无害，可随时删（会重新生成）。
- ~~计划任务 `\Hermes_Gateway`~~：**已于 2026-11-01 删除**（原指向不存在的 `hermes\gateway-service\Hermes_Gateway.vbs`，
  每分钟重试报 `0x80070002`，是 9 月装 Hermes agent 的残留，与本案无关）。
- ~~`Guest` 账号启用~~：**已于 2026-11-01 禁用**。
- ~~计划任务 `\Hermes_Gateway`~~：**已于 2026-11-01 删除**（原指向不存在的 `hermes\gateway-service\Hermes_Gateway.vbs`，
  每分钟重试报 `0x80070002`，是 9 月装 Hermes agent 的残留，与本案无关）。
- ~~`Guest` 账号启用~~：**已于 2026-11-01 禁用**。
