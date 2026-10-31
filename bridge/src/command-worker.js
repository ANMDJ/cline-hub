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
 * 执行方式由 config.commands.template 决定，模板里可用 {prompt} / {mode} / {workspace} 占位符：
 *   - 纯 shell：template = "{prompt}"（默认，把 prompt 当脚本跑）
 *   - 接 Cline CLI：template = "cline --yolo \"{prompt}\""
 * 脚本会先落成临时文件再交给 shell 执行，避免引号/换行转义踩坑。
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

export function createCommandWorker({ cfg, logger }) {
  const opts = cfg.commands ?? {}
  const enabled = Boolean(opts.enabled)
  const shellName = SHELLS[opts.shell] ? opts.shell : 'powershell'
  const shell = SHELLS[shellName]
  const template = String(opts.template ?? '').trim()
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

  function runScript(script, cwd) {
    return new Promise((resolve) => {
      fs.mkdirSync(tmpDir, { recursive: true })
      const file = path.join(tmpDir, `cmd_${Date.now()}_${Math.random().toString(16).slice(2, 8)}${shell.ext}`)
      fs.writeFileSync(file, script, 'utf8')

      const child = spawn(shell.command, shell.args(file), {
        cwd,
        windowsHide: true,
        env: { ...process.env, CLINE_HUB_COMMAND: '1' }
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
      }, timeoutMs)

      const finish = (code, message) => {
        clearTimeout(timer)
        state.child = null
        try {
          fs.unlinkSync(file)
        } catch {}
        resolve({ code, output, timedOut, message })
      }

      child.on('error', (error) => finish(-1, error.message))
      child.on('close', (code) => finish(code ?? -1, ''))
    })
  }

  function resolveWorkspace(command) {
    const wanted = String(command.workspace ?? '').trim()
    if (wanted && fs.existsSync(wanted) && fs.statSync(wanted).isDirectory()) return wanted
    if (defaultWorkspace && fs.existsSync(defaultWorkspace)) return defaultWorkspace
    return bridgeRoot
  }

  async function handle(command) {
    const mode = String(command.mode ?? 'plan').toLowerCase()

    if (!template) {
      await report(command.id, 'failed', { errorText: 'commands.template is empty in bridge/config.json' })
      logger.warn('command rejected: empty template', { id: command.id })
      return
    }
    if (!allowModes.includes(mode)) {
      await report(command.id, 'failed', {
        errorText: `mode "${mode}" is not allowed on this device (commands.allowModes: ${allowModes.join(', ')})`
      })
      logger.warn('command rejected: mode not allowed', { id: command.id, mode })
      return
    }

    const cwd = resolveWorkspace(command)
    const script = fillTemplate(template, {
      prompt: truncate(command.prompt, 8000),
      mode,
      workspace: cwd
    })

    logger.info('command started', { id: command.id, mode, cwd, chars: script.length })
    try {
      await report(command.id, 'running')
    } catch (error) {
      logger.error('command running-report failed', { id: command.id, message: error.message })
    }

    const result = await runScript(script, cwd)
    const ok = !result.timedOut && result.code === 0
    const body = ok
      ? { resultText: truncate(result.output) || '(no output)' }
      : {
          resultText: truncate(result.output),
          errorText: result.timedOut
            ? `timeout after ${timeoutMs}ms`
            : (result.message || `exit code ${result.code}`)
        }

    try {
      await report(command.id, ok ? 'done' : 'failed', body)
      logger.info('command finished', {
        id: command.id,
        status: ok ? 'done' : 'failed',
        exit: result.code,
        outChars: result.output.length
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
