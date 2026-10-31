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
