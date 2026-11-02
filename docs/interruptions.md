# 主动中断记录（interruptions）

> **这个文件是给「下一次会话」看的**：bridge 是命令执行者，它一停，手机上的命令就断了。
> 所以每次主动杀 bridge / 杀命令，都先在下面记一条：**为什么杀、怎么杀的、影响了谁、怎么恢复**。
> 下次开工读 §2，就知道上次为什么断在半路，不用靠猜。

## 0. 规矩（改流程先改这里）

1. **先停任务、再杀进程**：
   ```powershell
   cd bridge
   npm run stop -- --reason "升级 bridge / 换配置"     # 先回写执行中的命令，再杀进程树，最后退出
   npm run restart -- --reason "升级 bridge"           # 同上 + detached 重启
   ```
   `npm run stop` 走本机 `POST /admin/stop`：`command-worker.shutdown()` 会先并发 PATCH
   所有「执行中」的命令为 `failed`，`errorText` 写清「bridge 正在关闭（原因）」，**然后**才
   `taskkill /t /f`，最后 `process.exit(0)`。
   > 旧版本 bridge 没有这个入口（返回 404）时，脚本自动退化为
   > 「读本机登记 → 先 PATCH in-flight 命令 → 再硬杀 →（`--restart` 时）拉起」，
   > 顺序仍然是**先恢复状态、后杀进程**；从新进程起就走上面的优雅路径。
2. **不要**用 `Stop-Process` / `taskkill /pid` 直接杀 bridge。Windows 上那是
   `TerminateProcess`，Node 收不到 `SIGTERM`，`shutdown()` 根本不执行 —— 状态没回写、
   子进程可能变孤儿，手机上的卡片就停在「执行中」。
3. 只想停**某一条命令**：`npm run ps` 看 commandId → pid，`npm run ps -- --kill <commandId>`
   （pid + 启动时间双校验）。不要按 `node.exe` / `cline` 进程名杀。
4. 硬杀之后必须补一次对账：`npm run reconcile`（bridge 自己启动时 + 每 60s 也会做）。
5. **事后在本文件 §2 末尾追加一条**（格式见 §1）。

## 1. 记录模板

```md
### YYYY-MM-DD HH:mm 标题（一句话）

- **为什么杀**：例如「让 P13 对账逻辑生效」/「换 bridge/config.json 的 provider」。
- **怎么杀的**：`npm run stop -- --reason "..."`（优雅）或 ❌ 硬杀（写明是哪条命令）。
- **受影响**：`cmd_xxx`（mode / 跑了多久）→ 回写 `failed`，原因「bridge 正在关闭（…）」；
  没有执行中的命令就写「无」。
- **恢复**：`npm run restart -- --reason "..."`；`/health` 是否正常；命令有没有重新下发。
- **遗留**：需要下一会话接着做的事（没有就写「无」）。
```

## 2. 历史

### 2026-11-02 03:40–03:59 命令卡在「执行中」19 分钟

- **为什么杀**：让 P13 之前的 bridge 重启（当时还没有优雅退出）。
- **怎么杀的**：直接杀进程 —— ❌ 旧实现 `shutdown()` 里先 `killTree()` 再
  `process.exit(0)`，回写 `failed` 的 PATCH 没来得及发出去。
- **受影响**：`cmd_3ced4a851f4c`（03:40 领取，bridge 03:47 重启）一直显示「执行中」，
  直到 03:59 人工 `npm run reconcile` 才回写 `failed`。
- **恢复**：P13 对账（启动 + 每 60s）已上线；本次又补了「先回写、再杀、再退出」的
  `npm run stop` / `npm run restart`（ADR-36），下次重启不会再卡。
- **遗留**：无。

### 2026-11-02 12:15 P16 落地：没能当场重启 bridge（本会话就是 bridge 的子进程）

- **为什么没杀**：当时正在跑的 `cmd_010606ceba24` 就是**当前这个 Cline 会话**，
  它由 bridge 拉起；任何重启都会先杀掉本会话，改到一半的代码就有丢失风险。
  所以这一轮只改了代码 + 测试，不动线上进程。
- **怎么验证的**：`cd bridge; node --test`，其中新增的集成用例用「假 Hub + PowerShell
  睡 30 秒」真跑了一遍 `shutdown()`，断言 **`failed` 的 PATCH 在杀进程之前就已发出**，
  并且 `handle()` 不会再用 `exit code -1` 覆盖原因（23 项全绿）。
- **当前线上的 bridge 还是旧版本**（没有 `POST /admin/stop`）。下一次重启请执行：
  ```powershell
  cd bridge
  npm run restart -- --reason "让 P16 优雅停止生效"
  ```
  脚本会先检测到 404，于是按「脚本侧先回写 in-flight 命令 → 再硬杀 → 再拉起」；
  从新进程起，`npm run stop` / `npm run restart` 就走 `/admin/stop` 的优雅路径。
- **受影响（预期）**：执行中的命令（包括拉起这次重启的那条）会显示
  `failed：命令已中断：bridge 正在关闭（让 P16 优雅停止生效）…`，重新下发即可。
- **遗留**：重启后确认 `bridge/logs/bridge.log` 里有
  `shutting down` / `bridge started`，`/health` 为 `ok:true`。

### 2026-11-02 12:24–12:30 用户在命令里要求重启 bridge：会话被掐断，新会话接不上上下文

- **为什么杀**：用户在 `cmd_c4a49f60fccf`（act，12:24:45 下发）里要求「重启一下 bridge，
  让 P12/P16/P13 生效」。当时正在跑的 Cline 会话**就是**这条命令拉起的
  （session `1793593493423_cc793`）。
- **怎么杀的**：`npm run restart -- --keep-session --reason "加载 P12/P16/P13…"`。
  `--keep-session` 让脚本只杀 bridge、不 `taskkill /t` 子进程，并先回写：
  `cmd_c4a49f60fccf` → `failed`（12:27:51.472，errorText =「命令已中断：bridge 正在关闭
  （加载 P12/P16/P13…），执行进程已被停止」）。
- **实际结果（重要）**：`--keep-session` **并没有保住会话**。bridge 一退出，cline 子进程的
  stdout/stderr 管道（`stdio: ['ignore','pipe','pipe']`）就断了，session
  `1793593493423_cc793` 在 **12:28:10 以 exit code 1 结束**（约 19 秒后），
  上一轮对话因此断在半路。新 bridge 12:27:53 正常启动，启动对账把残留登记清掉。
- **恢复**：用户在 12:29:51 重新下发 `cmd_c2e5d2d05eec`，新会话
  `1793593797352_x21b8` 从 `docs/status.md` + 上一条会话的 `messages.json` 找回了原计划，
  继续开发（P6）。
- **结论 / 遗留**：
  1. **不要在 bridge 拉起的命令里重启 bridge**；等命令结束后再重启，或直接用 P18 的
     `npm run restart -- --when-idle`（detached supervisor 等执行中的命令跑完再重启）。
  2. `--keep-session` 的注释已改成「只保进程、保不住管道与会话」，别把它当万能开关。
  3. 每次重启前仍要按 §0 写一条记录，并在下次开工时先读这里。

