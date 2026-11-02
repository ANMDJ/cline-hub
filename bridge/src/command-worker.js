import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'

import {
  classifyRunningCommand,
  processLiveness,
  readEntries,
  readEntry,
  registryDir,
  removeEntry,
  writeEntry
} from './command-registry.js'
import { createClineJsonParser, isClineJsonFailure } from './cline-json.js'
import { inspectProcesses } from './process-info.js'

/**
 * 远程命令执行器（Hub → Windows）。
 *
 * 流程：轮询 GET /api/v1/commands/pending（服务端用 FOR UPDATE SKIP LOCKED 认领，天然防重）
 *      → PATCH status=running → 本地执行 → PATCH done/failed 回写结果。
 *
 * 执行方式由 config.commands.runner 决定：
 *   - 'cline'（推荐）：交给 cline CLI 真正进入一个 Cline 会话。
 *       一律 `cline -c <workspace> …` 新开会话（`--id` 续会话要求 TTY，无头环境不可用，见 ADR-18/19）。
 *       模式：plan 走 `-p`，act 走 `--auto-approve true`。
 *   - 'shell'：把 prompt 当脚本跑，模板里可用 {prompt} / {mode} / {workspace}。
 *       脚本先落成临时文件再交给 shell，避免引号/换行转义踩坑。
 *
 * 安全（2026-11-01 排查后补）：`workspaceWhitelist` 不为空时，命令的工作目录必须命中
 * 白名单，否则直接 failed。采集侧的白名单只决定「上报哪些会话」，完全管不到「在哪执行」，
 * 所以执行侧必须自己校验一次，否则手机发一句 `workspace=C:\Windows\System32` 就能到处跑脚本。
 */

const SHELLS = {
  powershell: { ext: '.ps1', command: 'powershell.exe', args: (file) => ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', file] },
  cmd: { ext: '.cmd', command: process.env.ComSpec ?? 'cmd.exe', args: (file) => ['/d', '/s', '/c', file] },
  bash: { ext: '.sh', command: 'bash', args: (file) => [file] }
}

const RESULT_LIMIT = 20000

/**
 * Hub 上 running 的命令多久对一次账。
 *
 * bridge 崩溃 / 被重启时，子进程要么跟着没了、要么留在本机成为孤儿；
 * 会话侧会自己翻成 failed，但命令状态只有 bridge 会写，没人对账就会一直「执行中」。
 * 60 秒是「手机上不会等太久」与「别把 Hub 打成轮询」的折中。
 */
const RECONCILE_INTERVAL_MS = 60 * 1000

/** 回写孤儿命令时给手机看的原因：说清楚「不是命令本身失败」，可以直接重发。 */
const ORPHAN_ERROR = '命令已中断：原来的执行进程不在了（bridge 重启 / 崩溃后没有接管）。可以重新下发。'

/**
 * 主动关闭 bridge 时回写给手机的原因。与 ORPHAN_ERROR 的区别：
 * 孤儿是「进程没了才被发现」，这条是「我们知道要关，先停了它再说」。
 */
export function interruptionErrorText(reason) {
  const why = String(reason ?? '').trim() || '未说明原因'
  return `命令已中断：bridge 正在关闭（${why}），执行进程已被停止。这不是命令执行失败，可以直接重新下发。`
}

/** `Promise.race` 的定时器必须在原 promise 结束时清掉，否则超时后 reject 变成 unhandled。 */
function withTimeout(promise, ms, label) {
  let timer
  return Promise.race([
    promise.finally(() => clearTimeout(timer)),
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`${label} timeout after ${ms}ms`)), ms)
    })
  ])
}

function truncate(text, limit = RESULT_LIMIT) {
  const value = String(text ?? '')
  if (value.length <= limit) return value
  return `${value.slice(0, limit)}\n…[truncated ${value.length - limit} chars]`
}

function fillTemplate(template, { prompt, mode, workspace }) {
  return String(template)
    .replaceAll('{prompt}', prompt)
    .replaceAll('{mode}', mode)
    .replaceAll('{workspace}', workspace)
}

function toArgs(value, fallback) {
  if (!Array.isArray(value)) return [...fallback]
  return value.map((item) => String(item)).filter((item) => item !== '')
}

/**
 * cmd.exe 的参数引号规则：含空格或 shell 元字符时整体加双引号。
 * 中文 prompt 一般是纯文本，这里只是兜底（`&`/`|` 在双引号内不被解释）。
 */
function quoteForCmd(value) {
  const text = String(value)
  if (text === '') return '""'
  if (!/[\s"&|<>^]/.test(text)) return text
  return `"${text.replaceAll('"', '""')}"`
}

/**
 * PowerShell 里「命令找不到」这类只是非终止错误，脚本照样以 0 退出，
 * 结果就是 App 显示 done、实际一件事没干（cmd_c7c2b2fd1662 那次）。
 * 前置 Stop 把它变成终止错误（exit 1），失败原因才能通过 errorText 回写。
 * 脚本自己写了 $ErrorActionPreference 的话以脚本为准（后赋值会覆盖前缀）。
 */
function hardenScript(script, shell) {
  if (shell.command !== 'powershell.exe') return script
  if (/^\s*\$ErrorActionPreference\s*=/m.test(script)) return script
  return `$ErrorActionPreference = 'Stop'\n${script}`
}

/**
 * 判断工作目录是否命中白名单（纯函数，便于 `scripts/check-workspace-whitelist.mjs` 自检）。
 *
 * - 白名单为空 → 不限制（保持旧行为，但 config 里必须显式写明风险）。
 * - 条目是绝对路径（`C:\...` / `/...`）→ 按目录前缀比较，`...\chat` 不会放行 `...\chatty`。
 * - 条目是纯名字（如 `kids_points_app`）→ 与目录名精确比较（与 index.js 采集侧同义）。
 */
export function isWorkspaceAllowed(dir, whitelist) {
  const entries = Array.isArray(whitelist)
    ? whitelist.map((item) => String(item).trim()).filter(Boolean)
    : []
  if (entries.length === 0) return true

  const target = path.resolve(dir)
  const targetLower = target.toLowerCase()
  const nameLower = path.basename(target).toLowerCase()

  return entries.some((entry) => {
    if (!/^([a-zA-Z]:[\\/]|[\\/])/.test(entry)) return nameLower === entry.toLowerCase()
    const allowedLower = path.resolve(entry).toLowerCase()
    return targetLower === allowedLower || targetLower.startsWith(`${allowedLower}${path.sep}`)
  })
}

export function createCommandWorker({ cfg, logger }) {
  const opts = cfg.commands ?? {}
  const enabled = Boolean(opts.enabled)
  /**
   * runner 决定「App 发来的一句话」怎么落地：
   *   shell → 当成 PowerShell 脚本跑（只适合执行指令）
   *   cline → 交给 cline CLI，真正进入一个 Cline 会话（默认）
   */
  const runner = opts.runner === 'cline' ? 'cline' : 'shell'
  const shellName = SHELLS[opts.shell] ? opts.shell : 'powershell'
  const shell = SHELLS[shellName]
  const template = String(opts.template ?? '').trim()
  const clineOpts = {
    bin: String(opts.cline?.bin ?? '').trim(),
    jsEntry: String(opts.cline?.jsEntry ?? '').trim(),
    /**
     * provider / model：无头运行必须显式指定，否则 CLI 会吃 `~/.cline` 里
     * `providers.json` 的 `lastUsedProvider`（可能是免费额度模型，随时下线）。
     * 2026-11-01 实测：不指定时用的是 `cline-free/*`，官方下线后每次 exit 1。
     */
    provider: String(opts.cline?.provider ?? '').trim(),
    model: String(opts.cline?.model ?? '').trim(),
    planArgs: toArgs(opts.cline?.planArgs, ['-p']),
    actArgs: toArgs(opts.cline?.actArgs, ['--auto-approve', 'true']),
    extraArgs: toArgs(opts.cline?.extraArgs, []),
    /**
     * `--json`（默认开）：CLI 改用 NDJSON 输出结构化事件，终稿 / 失败原因 / 用量
     * 都有明确字段（见 src/cline-json.js 与 ADR-38）。老版本 CLI 不支持时在
     * `commands.cline.json=false` 退回原来的纯文本输出。
     */
    json: opts.cline?.json !== false,
    /**
     * Cline CLI 3.0.74 没有 `--act`：`modeExplicitlySet` 只认 --plan/--yolo/--zen，
     * 其余情况模式取 `settings/global-settings.json` 的 `planActMode`（上一次 UI 停留的模式）。
     * 于是手机发 act、CLI 却按 plan 跑（2026-11-02 实测），关掉这个开关就退回旧行为。
     */
    forceModeEnv: opts.cline?.forceModeEnv !== false,
    // resume 已停用：--id 需要 TTY，无头 bridge 用不了（见 runCline 注释）。
    resume: false,
    timeoutMs: Number.isFinite(Number(opts.cline?.timeoutMs)) && Number(opts.cline?.timeoutMs) > 0
      ? Number(opts.cline.timeoutMs)
      : 1800000
  }
  // Windows 上 cline 通常不在 PATH 里，config.commands.cline.bin 要写绝对路径的 cline.cmd。
  const clineBin = clineOpts.bin || 'cline'
  const allowModes = Array.isArray(opts.allowModes) && opts.allowModes.length > 0
    ? opts.allowModes.map((m) => String(m).toLowerCase())
    : ['plan', 'act']
  const timeoutMs = Number.isFinite(Number(opts.timeoutMs)) && Number(opts.timeoutMs) > 0
    ? Number(opts.timeoutMs)
    : 600000
  const batchSize = Number.isFinite(Number(opts.batchSize)) && Number(opts.batchSize) > 0
    ? Math.min(10, Number(opts.batchSize))
    : 3
  const defaultWorkspace = opts.defaultWorkspace ? path.resolve(opts.defaultWorkspace) : ''

  /**
   * 与 index.js 的采集白名单共用同一个配置项，作用却完全不同：
   * 那边决定「哪些会话能上报」，这边决定「命令在哪些目录能落地」。
   */
  const workspaceWhitelist = Array.isArray(cfg.workspaceWhitelist)
    ? cfg.workspaceWhitelist.map((item) => String(item).trim()).filter(Boolean)
    : []

  const tmpDir = path.join(os.tmpdir(), 'cline-hub-cmd')
  /**
   * `children`: commandId → { child, entry }。
   * 以前只有一个 `state.child` 槽位，并发后 stop()/超时只能杀到最后一条；
   * 现在按 commandId 精确对应，bridge 退出时能把所有子进程一起收掉（不流孤儿）。
   */
  const state = {
    ticking: false,
    busy: false,
    warned: false,
    stopped: false,
    children: new Map(),
    /** commandId → 中断原因：shutdown 已经回写 failed，handle() 别再抢着报一次。 */
    interrupted: new Map(),
    /** 防止 SIGINT 与 /admin/stop 同时进来跑两遍。 */
    shuttingDown: false,
    /** 上次对账时间 + 是否在跑：避免 tick 每 5 秒叠一次请求。 */
    lastReconcileAt: 0,
    reconciling: false
  }
  const registry = registryDir()

  async function request(method, pathname, body) {
    const headers = { 'content-type': 'application/json; charset=utf-8' }
    if (cfg.deviceToken) headers.authorization = `Bearer ${cfg.deviceToken}`
    const response = await fetch(`${cfg.hubUrl}${pathname}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(15000)
    })
    const text = await response.text()
    if (!response.ok) {
      throw new Error(`${method} ${pathname} -> ${response.status} ${truncate(text, 200)}`)
    }
    try {
      return text ? JSON.parse(text) : null
    } catch {
      return null
    }
  }

  function report(id, status, extra = {}) {
    return request('PATCH', `/api/v1/commands/${encodeURIComponent(id)}`, { status, ...extra })
  }

  /**
   * Hub 上还是 `running` 的命令，本机是否还有对应进程 —— 没了的回写 `failed: orphaned`。
   *
   * 触发场景（2026-11-02 实测）：bridge 重启时把 in-flight 的 cline 子进程一起带走，
   * 会话侧由 index.js 自己的状态跃迁翻成 failed，但 commands 表没人再写，
   * 手机上的命令卡片就永远停在「执行中」。这不是命令失败、也不是会话失败，
   * 而是「执行者没了」，所以单独给一条能看懂的原因。
   *
   * 安全边界：
   * - 只改状态，**不杀任何进程**；存活只看 pid + 启动时间；
   * - 本进程 children 里的命令一律跳过（正常运行中）；
   * - 时间戳缺失 / 刚领取（< `ORPHAN_GRACE_MS`）一律留观，避免误判。
   */
  async function reconcile({ dryRun = false, limit = 50 } = {}) {
    if (!enabled) return { ok: true, skipped: 'disabled', checked: 0, orphaned: 0 }
    if (!cfg.hubUrl) return { ok: true, skipped: 'no_hub', checked: 0, orphaned: 0 }
    if (state.reconciling) return { ok: true, skipped: 'busy', checked: 0, orphaned: 0 }

    state.reconciling = true
    try {
      const query = `deviceId=${encodeURIComponent(cfg.deviceId)}&status=running&limit=${limit}`
      const data = await request('GET', `/api/v1/commands?${query}`)
      const items = Array.isArray(data?.items) ? data.items : []
      const nowMs = Date.now()

      // 一次 PowerShell 查询把所有相关 pid 取回来（逐条查会慢到秒级）。
      const entries = new Map()
      const pids = []
      for (const item of items) {
        if (state.children.has(item.id)) continue
        const fromDisk = readEntry(registry, item.id)
        // 登记文件可能被 %TEMP% 清理掉；Hub 上的 pid + pidStartedAt 是第二证据。
        const fromHub = item.pid
          ? { pid: item.pid, pidStartedAt: item.pidStartedAt ?? null }
          : null
        const entry = fromDisk ?? fromHub
        entries.set(item.id, entry)
        if (entry?.pid) pids.push(Number(entry.pid))
      }
      const processes = inspectProcesses(pids)

      const orphans = []
      for (const item of items) {
        const entry = entries.get(item.id) ?? null
        const owned = state.children.has(item.id)
        const { alive, verified } = processLiveness(entry, processes)
        const verdict = classifyRunningCommand({
          command: { startedAt: item.startedAt, createdAt: item.createdAt },
          entry,
          alive,
          verified,
          owned,
          nowMs
        })
        if (verdict === 'orphaned') orphans.push(item)
      }

      let cleaned = []
      if (!dryRun) {
        for (const item of orphans) {
          try {
            await report(item.id, 'failed', { errorText: ORPHAN_ERROR })
            removeEntry(registry, item.id)
            logger.warn('command orphaned', {
              id: item.id,
              startedAt: item.startedAt ?? item.createdAt ?? null,
              pid: entries.get(item.id)?.pid ?? null
            })
          } catch (error) {
            // 单条失败不影响其他命令：下一轮对账还会看到它。
            logger.error('orphan report failed', { id: item.id, message: error.message })
          }
        }
        cleaned = cleanStaleEntries()
      }

      return {
        ok: true,
        dryRun,
        checked: items.length,
        orphaned: orphans.length,
        ids: orphans.map((item) => item.id),
        cleaned
      }
    } finally {
      state.reconciling = false
      state.lastReconcileAt = Date.now()
    }
  }

  /**
   * 登记目录里进程已经不在（或 pid 被复用）的文件清掉，`npm run ps` 才不会显示假条目。
   * 只碰不在 `children` 里的 —— 正在跑的命令登记必须保留。
   */
  function cleanStaleEntries() {
    const entries = readEntries(registry).filter((entry) => !state.children.has(entry.commandId))
    if (entries.length === 0) return []
    const processes = inspectProcesses(entries.map((entry) => Number(entry.pid)))
    const stale = entries.filter((entry) => {
      const { alive, verified } = processLiveness(entry, processes)
      return !(alive && verified)
    })
    for (const entry of stale) removeEntry(registry, entry.commandId)
    return stale.map((entry) => entry.commandId)
  }

  /**
   * spawn 成功那一刻把「这条命令 = 这个进程」记到三个地方：
   *   1. 内存 Map：超时 / bridge 退出时按 commandId 精确杀，不再只有一个槽位；
   *   2. `%TEMP%\cline-hub-cmd\running\<id>.json`：bridge 崩了也能用 `npm run ps` 找回孤儿；
   *   3. Hub：pid + pidStartedAt 一起回写，手机上能直接看到进程身份。
   *
   * pidStartedAt 取 spawn 返回后的本地时间，与 Windows CreationDate 的误差在毫秒级；
   * ps 侧留 5 秒容差，超过就当作 PID 已被复用，拒绝杀。
   */
  function registerChild(identity, child) {
    const pidStartedAt = new Date().toISOString()
    const entry = {
      commandId: identity.id,
      pid: child.pid ?? null,
      pidStartedAt,
      workspace: identity.workspace ?? null,
      mode: identity.mode ?? null,
      runner: identity.runner ?? null,
      bridgePid: process.pid,
      executable: identity.executable ?? null,
      startedAt: pidStartedAt
    }
    state.children.set(identity.id, { child, entry })
    try {
      writeEntry(registry, entry)
    } catch (error) {
      logger.warn('command registry write failed', { id: identity.id, message: error.message })
    }
    logger.info('command process spawned', {
      id: identity.id,
      pid: entry.pid,
      runner: entry.runner,
      executable: entry.executable
    })
    if (!entry.pid) return entry
    // 不 await：进程已经开跑，上报失败只影响手机上的 pid 展示，不能让命令卡住。
    report(identity.id, 'running', {
      pid: entry.pid,
      pidStartedAt,
      runner: entry.runner
    })
      .then(() => logger.info('command process reported', { id: identity.id, pid: entry.pid }))
      .catch((error) => logger.error('command process report failed', {
        id: identity.id,
        message: error.message
      }))
    return entry
  }

  function unregisterChild(commandId) {
    if (!state.children.has(commandId)) return
    state.children.delete(commandId)
    try {
      removeEntry(registry, commandId)
    } catch {}
  }

  /**
   * cline 每次运行都会在 `<dataDir>/sessions/<id>/<id>.json` 落一份元数据，
   * 里面同时有 `session_id` / `cwd` / `started_at`。命令记录要回写会话 ID，
   * 就靠「运行前快照 + 运行中轮询新增目录」拿。
   */
  const sessionsDir = path.join(cfg.dataDir, 'sessions')

  function listSessionIds() {
    try {
      return new Set(fs.readdirSync(sessionsDir))
    } catch {
      return new Set()
    }
  }

  function readSessionMeta(id) {
    try {
      return JSON.parse(fs.readFileSync(path.join(sessionsDir, id, `${id}.json`), 'utf8'))
    } catch {
      return null
    }
  }

  function samePath(a, b) {
    if (!a || !b) return false
    const norm = (value) => path.resolve(String(value)).replace(/\\/g, '/').toLowerCase()
    return norm(a) === norm(b)
  }

  /**
   * 本次运行新建的会话：新增目录里挑 `cwd` / `workspace_root` 与工作目录一致的那个；
   * 并发跑多条命令时靠这一步区分，只有一个新增时直接用它。
   */
  function findNewSession(before, cwd) {
    let entries = []
    try {
      entries = fs.readdirSync(sessionsDir)
    } catch {
      return null
    }
    const fresh = entries.filter((id) => !before.has(id))
    if (fresh.length === 0) return null
    for (const id of fresh) {
      const meta = readSessionMeta(id)
      if (!meta) continue
      if (samePath(meta.cwd, cwd) || samePath(meta.workspace_root, cwd)) return id
    }
    return fresh.length === 1 ? fresh[0] : null
  }

  /**
   * 失败原因：光写 `exit code 1` 在手机上等于没说，
   * 把 stderr 里第一条像错误的行带出来（PowerShell 的 CommandNotFoundException 就在那）。
   */
  function failureReason(result, limitMs = timeoutMs) {
    if (result.timedOut) return `timeout after ${limitMs}ms`
    if (result.message) return result.message
    const lines = String(result.output ?? '')
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean)
    const hit = lines.find((line) => /error|not recognized|not found|denied|cannot|无法|不是/i.test(line)) ?? lines[0] ?? ''
    const reason = truncate(hit, 300)
    return reason ? `exit code ${result.code}: ${reason}` : `exit code ${result.code}`
  }

  function killTree(child) {
    if (process.platform === 'win32') {
      spawn('taskkill', ['/pid', String(child.pid), '/t', '/f'], { windowsHide: true })
        .on('error', () => {})
      return
    }
    try {
      child.kill('SIGKILL')
    } catch {}
  }

  function runProcess(command, args, cwd, limitMs, options = {}) {
    const useShell = options.shell === true
    const identity = options.identity ?? null
    return new Promise((resolve) => {
      const child = spawn(command, useShell ? args.map(quoteForCmd) : args, {
        cwd,
        windowsHide: true,
        // stdin 必须是 ignore：不然 cline 会等终端输入，进程永远不退出，
        // 命令在手机上看就是「一直执行中」（cmd_1757ca588f92 那次）。
        stdio: ['ignore', 'pipe', 'pipe'],
        shell: useShell,
        env: { ...process.env, CLINE_HUB_COMMAND: '1', ...(options.env ?? {}) }
      })
      // spawn 失败时没有 pid，不登记（否则 ps 会看到一条 pid=null 的假记录）。
      if (identity && child.pid) registerChild(identity, child)

      let output = ''
      let timedOut = false
      const collect = (chunk) => {
        output += chunk.toString('utf8')
        if (output.length > RESULT_LIMIT * 2) output = output.slice(-RESULT_LIMIT)
      }
      child.stdout?.on('data', (chunk) => {
        collect(chunk)
        // 只把 stdout 喂给结构化解析器：stderr 里是 CLI 的告警，不参与 NDJSON。
        try {
          options.onStdout?.(chunk)
        } catch {}
      })
      child.stderr?.on('data', collect)

      const timer = setTimeout(() => {
        timedOut = true
        killTree(child)
      }, limitMs)

      const finish = (code, message) => {
        clearTimeout(timer)
        // 进程结束（正常/失败/被杀）就撤掉登记：`npm run ps` 只显示还活着的那几条。
        if (identity) unregisterChild(identity.id)
        resolve({ code, output, timedOut, message, pid: child.pid ?? null })
      }

      child.on('error', (error) => finish(-1, error.message))
      child.on('close', (code) => finish(code ?? -1, ''))
    })
  }

  function runScript(script, cwd, identity) {
    fs.mkdirSync(tmpDir, { recursive: true })
    const file = path.join(tmpDir, `cmd_${Date.now()}_${Math.random().toString(16).slice(2, 8)}${shell.ext}`)
    fs.writeFileSync(file, script, 'utf8')
    return runProcess(shell.command, shell.args(file), cwd, timeoutMs, {
      identity: { ...identity, executable: shell.command }
    }).finally(() => {
      try {
        fs.unlinkSync(file)
      } catch {}
    })
  }

  /**
   * 找到把 cline 跑起来的最稳方式。
   *
   * Windows 上 cline 是 .cmd；spawn 时 shell:true 会让 cmd 重新解析整行，
   * bin 路径里一旦有空格（.../Author Software/...）就会被截断成
   * 'C:\Users\alice\AppData\Local\Author' is not recognized（cmd_d780a52e6c1a 实测）。
   * 所以优先用 node 直接跑 cline 的 JS 入口：没有 cmd、没有引号问题，stdin 仍可 ignore。
   */
  function resolveClineTarget() {
    const isBatch = process.platform === 'win32' && /\.(cmd|bat)$/i.test(clineBin)
    if (clineOpts.jsEntry && fs.existsSync(clineOpts.jsEntry)) {
      return { command: process.execPath, argv: [clineOpts.jsEntry], shell: false }
    }
    if (isBatch) {
      const derived = path.join(path.dirname(clineBin), 'node_modules', 'cline', 'bin', 'cline')
      if (fs.existsSync(derived)) {
        return { command: process.execPath, argv: [derived], shell: false }
      }
    }
    return { command: clineBin, argv: [], shell: isBatch }
  }

  /**
   * 让 CLI 真正按命令的模式跑。
   *
   * 实测（2026-11-02）：手机发 act → bridge 日志 `mode:"act"`、CLI 会话元数据
   * `metadata.mode:"act"`，但首条用户消息被包成 `<user_input mode="plan">`，
   * 模型于是按 plan 执行（只出方案、不改文件）。
   * 原因是 CLI 3.0.74 没有 `--act` 旗标，`--auto-approve` 只管审批、不改模式，
   * 不显式传 `-p/--yolo` 时模式来自 `settings/global-settings.json` 的 `planActMode`。
   *
   * 这里给每次运行注入一份临时 settings 文件，把 `planActMode` 钉死成命令模式。
   * providers.json 只做只读引用（CLINE_PROVIDER_SETTINGS_PATH），不复制任何密钥；
   * 临时文件落在 os.tmpdir()，不进仓库。
   */
  function clineModeEnv(mode) {
    if (!clineOpts.forceModeEnv) return {}
    const env = {}
    try {
      fs.mkdirSync(tmpDir, { recursive: true })
      const file = path.join(tmpDir, `cline-settings-${mode}.json`)
      fs.writeFileSync(
        file,
        JSON.stringify({
          planActMode: mode === 'plan' ? 'plan' : 'act',
          toolAutoApprove: true,
          autoUpdateEnabled: false,
          telemetryOptOut: true
        }, null, 2),
        'utf8'
      )
      env.CLINE_GLOBAL_SETTINGS_PATH = file
    } catch (error) {
      logger.warn('cline mode settings not written', { mode, message: error.message })
    }
    const providers = path.join(cfg.dataDir, 'settings', 'providers.json')
    if (fs.existsSync(providers)) env.CLINE_PROVIDER_SETTINGS_PATH = providers
    return env
  }

  /**
   * 把一条命令翻译成 cline CLI 的调用。
   *
   * 一律 `-c <workspace>` 新开会话：`--id` 续会话在无 TTY 下会直接报
   * "interactive mode requires a TTY"（见 ADR-18/19），bridge 是隐藏进程拿不到终端。
   * 模式：plan 走 `-p`（只读），act 走 `--auto-approve true`；yolo 由 allowModes 拦掉。
   */
  function runCline({ prompt, mode, cwd, sessionId, identity }) {
    const args = [...(mode === 'plan' ? clineOpts.planArgs : clineOpts.actArgs)]
    // 结构化输出：终稿、失败原因、用量都在事件里，不必再解析终端装饰。
    const jsonMode = clineOpts.json
    if (jsonMode) args.push('--json')
    // provider / model 必须显式传：CLI 缺省时会用 providers.json 里的
    // `lastUsedProvider`（可能是已下线的免费模型），无头运行直接 exit 1。
    if (clineOpts.provider) args.push('-P', clineOpts.provider)
    if (clineOpts.model) args.push('-m', clineOpts.model)
    args.push(...clineOpts.extraArgs)
    // cline CLI 4.x 的 --id 续会话要求 TTY（非 TTY 下报
    // "interactive mode requires a TTY"），bridge 的 spawn 没有终端，
    // 所以带 sessionId 也一律 -c 新开会话（2026-11-01 实测）。
    args.push('-c', cwd)
    // 位置参数必须在最后：commander 会把 prompt 之后的一切当成 prompt 的一部分。
    // cline CLI 用 `/\s/` 判断「这串像不像 prompt」：完全不含空白的词会被当成子命令，
    // 直接报 `Unknown command or unquoted prompt: xxx`（2026-11-01 实测：
    // `java`、`安装包可以传给我吗` 都中招；带空格的中文句子正常）。
    // 中文用户一句话经常不打空格，所以这里补一个尾随空格，对模型语义无影响。
    args.push(/\s/.test(prompt) ? prompt : `${prompt} `)
    const target = resolveClineTarget()
    const parser = jsonMode ? createClineJsonParser({ maxTextChars: RESULT_LIMIT }) : null
    return runProcess(target.command, [...target.argv, ...args], cwd, clineOpts.timeoutMs, {
      shell: target.shell,
      env: clineModeEnv(mode),
      // cline 实际跑起来的是 node（JS 入口）或 cline.cmd；登记到 ps 里便于辨认。
      identity: { ...identity, executable: [target.command, ...target.argv].join(' ') },
      onStdout: parser ? (chunk) => parser.push(chunk) : undefined
    }).then((result) => ({
      ...result,
      // end() 负责 flush 最后一行：CLI 的 run_result 不一定带结尾换行。
      json: parser ? parser.end() : null
    }))
  }

  /**
   * 决定命令在哪个目录执行。
   *
   * 以前拿不到有效目录时会静默回落到 bridgeRoot（bridge 自己的源码目录），
   * 命令就在那儿乱跑；现在候选都无效就抛错，由 handle() 回写 failed。
   */
  function resolveWorkspace(command) {
    const wanted = String(command.workspace ?? '').trim()
    if (wanted && fs.existsSync(wanted) && fs.statSync(wanted).isDirectory()) return wanted
    if (defaultWorkspace && fs.existsSync(defaultWorkspace)) return defaultWorkspace
    throw new Error(
      'no usable workspace: 这条命令没带 workspace，且 commands.defaultWorkspace 未配置或不存在'
    )
  }

  async function handle(command) {
    const mode = String(command.mode ?? 'plan').toLowerCase()

    if (!allowModes.includes(mode)) {
      await report(command.id, 'failed', {
        errorText: `mode "${mode}" is not allowed on this device (commands.allowModes: ${allowModes.join(', ')})`
      })
      logger.warn('command rejected: mode not allowed', { id: command.id, mode })
      return
    }
    if (runner === 'shell' && !template) {
      await report(command.id, 'failed', { errorText: 'commands.template is empty in bridge/config.json' })
      logger.warn('command rejected: empty template', { id: command.id })
      return
    }

    let cwd
    try {
      cwd = resolveWorkspace(command)
    } catch (error) {
      await report(command.id, 'failed', { errorText: error.message })
      logger.warn('command rejected: no usable workspace', {
        id: command.id,
        wanted: command.workspace ?? null
      })
      return
    }
    if (!isWorkspaceAllowed(cwd, workspaceWhitelist)) {
      await report(command.id, 'failed', {
        errorText: `workspace "${cwd}" is not in workspaceWhitelist (${workspaceWhitelist.join(', ')})`
      })
      logger.warn('command rejected: workspace not whitelisted', { id: command.id, cwd })
      return
    }
    const sessionId = String(command.sessionId ?? '').trim()
    const prompt = truncate(command.prompt, 8000)

    logger.info('command started', {
      id: command.id,
      mode,
      runner,
      cwd,
      sessionId: sessionId || null,
      chars: prompt.length
    })
    try {
      await report(command.id, 'running')
    } catch (error) {
      logger.error('command running-report failed', { id: command.id, message: error.message })
    }

    // cline 会新开一个会话；先把目录快照下来，运行中一旦出现新会话就回写 ID，
    // 这样手机端在命令详情里能直接点进那条会话（否则 sessionId 永远是 null）。
    const sessionBefore = runner === 'cline' ? listSessionIds() : null
    let sessionWatcher = null
    const stopWatcher = () => {
      if (!sessionWatcher) return
      clearInterval(sessionWatcher)
      sessionWatcher = null
    }
    if (runner === 'cline') {
      sessionWatcher = setInterval(() => {
        const found = findNewSession(sessionBefore, cwd)
        if (!found) return
        stopWatcher()
        report(command.id, 'running', { sessionId: found })
          .then(() => logger.info('command session linked', { id: command.id, sessionId: found }))
          .catch((error) => logger.error('command session link failed', {
            id: command.id,
            message: error.message
          }))
      }, 1500)
    }

    const limitMs = runner === 'cline' ? clineOpts.timeoutMs : timeoutMs
    // 进程身份：id/mode/runner/workspace 由 runProcess 在 spawn 成功时写成
    // 本机登记 + 回写 Hub；手机端据此显示 pid 并复制排查命令。
    const identity = { id: command.id, mode, runner, workspace: cwd }
    let result
    try {
      result = runner === 'cline'
        ? await runCline({ prompt, mode, cwd, sessionId, identity })
        : await runScript(hardenScript(fillTemplate(template, { prompt, mode, workspace: cwd }), shell), cwd, identity)
    } finally {
      // 无论成功、失败还是抛异常，都要停掉会话轮询，否则定时器一直挂着。
      stopWatcher()
    }

    // 轮询可能还没跑到（命令很短），收尾时再查一次。
    const createdSession = runner === 'cline' ? findNewSession(sessionBefore, cwd) : null
    const link = createdSession ? { sessionId: createdSession } : {}

    // CLI 的模式可能被 global-settings 带走：跑完核对真实模式，
    // 不一致就在结果末尾留证据，别让手机上「看起来成功了」。
    const actualMode = createdSession
      ? String(readSessionMeta(createdSession)?.metadata?.mode ?? '')
      : ''
    const modeWarning = actualMode && actualMode !== mode
      ? `\n\n[cline-hub] 注意：命令要求 ${mode} 模式，CLI 实际以 ${actualMode} 模式运行。`
      : ''

    /**
     * `--json` 的终稿是干净文本（不带 `[thinking]`/ANSI/进度行）；只有在 CLI
     * 完全没吐 JSON（老版本 / 启动就崩）时才退回原始输出。失败原因同理：
     * 事件里的 error 比「stderr 第一行像错误的」准确。
     */
    const json = result.json ?? null
    const outputText = json?.sawJson ? (json.text ?? '') : result.output
    const jsonError = json?.errorMessage ? truncate(json.errorMessage, 300) : ''

    const ok = !result.timedOut && result.code === 0 && !isClineJsonFailure(json)
    // 主动关闭时 shutdown() 已经把这条命令回写成 failed（原因更准确），
    // 这里再报一次会把「bridge 关闭」覆盖成「exit code -1」，所以直接让位。
    if (state.interrupted.has(command.id)) {
      logger.info('command result skipped: interrupted at shutdown', { id: command.id })
      return
    }
    const body = ok
      ? { ...link, resultText: (truncate(outputText) || '(no output)') + modeWarning }
      : {
          ...link,
          resultText: truncate(outputText) + modeWarning,
          errorText: jsonError || failureReason(result, limitMs)
        }

    try {
      await report(command.id, ok ? 'done' : 'failed', body)
      logger.info('command finished', {
        id: command.id,
        runner,
        status: ok ? 'done' : 'failed',
        exit: result.code,
        pid: result.pid ?? null,
        outChars: outputText.length,
        sessionId: createdSession ?? null,
        actualMode: actualMode || null,
        json: Boolean(json?.sawJson),
        finishReason: json?.finishReason ?? null,
        taskId: json?.taskId ?? null,
        toolCalls: json?.toolCalls ?? null,
        outputTokens: json?.usage?.outputTokens ?? null,
        cost: json?.usage?.totalCost ?? null
      })
    } catch (error) {
      logger.error('command result report failed', { id: command.id, message: error.message })
    }
  }

  async function tick() {
    if (state.stopped) return
    if (!enabled) {
      if (!state.warned) {
        logger.info('command worker disabled (set commands.enabled=true in bridge/config.json)')
        state.warned = true
      }
      return
    }
    if (state.ticking || state.busy || !cfg.hubUrl) return

    // 对账不阻塞领取：每 60 秒顺手确认一次「Hub 上 running 的命令本机还活着吗」。
    if (!state.reconciling && Date.now() - state.lastReconcileAt >= RECONCILE_INTERVAL_MS) {
      reconcile().catch((error) => logger.warn('command reconcile failed', { message: error.message }))
    }

    state.ticking = true
    try {
      const query = `deviceId=${encodeURIComponent(cfg.deviceId)}&limit=${batchSize}`
      const data = await request('GET', `/api/v1/commands/pending?${query}`)
      const items = Array.isArray(data?.items) ? data.items : []
      if (items.length === 0) return

      state.busy = true
      logger.info('commands claimed', { count: items.length })
      try {
        for (const item of items) {
          if (state.stopped) break
          await handle(item)
        }
      } finally {
        state.busy = false
      }
    } catch (error) {
      logger.warn('command poll failed', { message: error.message })
    } finally {
      state.ticking = false
    }
  }

  /**
   * 优雅退出：**先**把正在跑的命令回写成 failed 并说明原因，**再**杀进程树。
   *
   * 为什么顺序不能反（2026-11-02 的教训）：旧实现在 shutdown 里直接 killTree()
   * 然后 process.exit(0)。进程确实停了，但「回写 failed」的那次 PATCH 还没发出去，
   * 手机上的命令就永远停在「执行中」，直到下一次启动对账或人工 reconcile 才收尾
   * （cmd_3ced4a851f4c 卡了 19 分钟）。
   *
   * 现在：并发 PATCH（每条 3 秒超时）→ 杀进程树 → 由 index.js 退出。
   * 回写失败也不阻塞退出，下一次启动的 reconcile() 会兜底。
   *
   * `keepChildren`（`npm run restart -- --keep-session`）：同样先回写 failed，但**不杀**
   * 子进程。只在「进程还要继续跑、结果不再需要 bridge 收」时用；**保不住会话**：
   * bridge 一退出，子进程的 stdout/stderr 管道就断，cline 会自己 exit 1
   * （2026-11-02 12:24 实测，见 docs/interruptions.md）。要重启又不掐断当前命令，
   * 用 P18 的 `npm run restart -- --when-idle`。
   */
  async function shutdown({ reason = 'bridge shutdown', reportTimeoutMs = 3000, keepChildren = false } = {}) {
    if (state.shuttingDown) return { interrupted: [], reported: [] }
    state.shuttingDown = true
    state.stopped = true

    const inflight = [...state.children.entries()]
    if (inflight.length === 0) return { interrupted: [], reported: [] }

    const errorText = interruptionErrorText(reason)
    logger.warn('interrupting in-flight commands before shutdown', {
      reason,
      ids: inflight.map(([id]) => id)
    })

    const results = await Promise.allSettled(inflight.map(([id]) => {
      state.interrupted.set(id, reason)
      return withTimeout(report(id, 'failed', { errorText }), reportTimeoutMs, `PATCH ${id}`)
    }))

    const reported = []
    results.forEach((result, index) => {
      const id = inflight[index][0]
      if (result.status === 'fulfilled') reported.push(id)
      else logger.error('command interrupt report failed', {
        id,
        message: result.reason?.message ?? String(result.reason)
      })
    })

    if (keepChildren) {
      logger.warn('in-flight commands left running (keepChildren)', {
        reason,
        interrupted: inflight.length,
        reported: reported.length
      })
    } else {
      for (const { child } of [...state.children.values()]) killTree(child)
      logger.warn('in-flight commands stopped', {
        reason,
        interrupted: inflight.length,
        reported: reported.length
      })
    }
    return { interrupted: inflight.map(([id]) => id), reported, keptChildren: keepChildren }
  }

  function stop() {
    state.stopped = true
    // 应急路径：只杀进程、不写状态（正常停 bridge 请用 shutdown，见 npm run stop）。
    // 先复制一份：killTree 会触发 close → unregisterChild 改动 Map。
    for (const { child } of [...state.children.values()]) killTree(child)
  }

  return { tick, stop, shutdown, reconcile, get enabled() { return enabled } }
}
