import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'

import { bridgeRoot } from './config.js'

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
  const state = { ticking: false, busy: false, warned: false, child: null, stopped: false }

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
      state.child = child

      let output = ''
      let timedOut = false
      const collect = (chunk) => {
        output += chunk.toString('utf8')
        if (output.length > RESULT_LIMIT * 2) output = output.slice(-RESULT_LIMIT)
      }
      child.stdout?.on('data', collect)
      child.stderr?.on('data', collect)

      const timer = setTimeout(() => {
        timedOut = true
        killTree(child)
      }, limitMs)

      const finish = (code, message) => {
        clearTimeout(timer)
        state.child = null
        resolve({ code, output, timedOut, message })
      }

      child.on('error', (error) => finish(-1, error.message))
      child.on('close', (code) => finish(code ?? -1, ''))
    })
  }

  function runScript(script, cwd) {
    fs.mkdirSync(tmpDir, { recursive: true })
    const file = path.join(tmpDir, `cmd_${Date.now()}_${Math.random().toString(16).slice(2, 8)}${shell.ext}`)
    fs.writeFileSync(file, script, 'utf8')
    return runProcess(shell.command, shell.args(file), cwd, timeoutMs).finally(() => {
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
  function runCline({ prompt, mode, cwd, sessionId }) {
    const args = [...(mode === 'plan' ? clineOpts.planArgs : clineOpts.actArgs)]
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
    return runProcess(target.command, [...target.argv, ...args], cwd, clineOpts.timeoutMs, {
      shell: target.shell,
      env: clineModeEnv(mode)
    })
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
    let result
    try {
      result = runner === 'cline'
        ? await runCline({ prompt, mode, cwd, sessionId })
        : await runScript(hardenScript(fillTemplate(template, { prompt, mode, workspace: cwd }), shell), cwd)
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

    const ok = !result.timedOut && result.code === 0
    const body = ok
      ? { ...link, resultText: (truncate(result.output) || '(no output)') + modeWarning }
      : {
          ...link,
          resultText: truncate(result.output) + modeWarning,
          errorText: failureReason(result, limitMs)
        }

    try {
      await report(command.id, ok ? 'done' : 'failed', body)
      logger.info('command finished', {
        id: command.id,
        runner,
        status: ok ? 'done' : 'failed',
        exit: result.code,
        outChars: result.output.length,
        sessionId: createdSession ?? null,
        actualMode: actualMode || null
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

  function stop() {
    state.stopped = true
    if (state.child) killTree(state.child)
  }

  return { tick, stop, get enabled() { return enabled } }
}
