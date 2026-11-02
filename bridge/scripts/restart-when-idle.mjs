import fs from 'node:fs'
import path from 'node:path'
import { spawn } from 'node:child_process'

import { bridgeRoot } from '../src/config.js'
import { readEntries, registryDir } from '../src/command-registry.js'
import { inspectProcesses } from '../src/process-info.js'
import {
  isSupervisorAlive,
  readSupervisorLock,
  removeSupervisorLock,
  waitForIdle,
  writeSupervisorLock
} from '../src/idle-restart.js'

/**
 * 「等执行中的命令跑完，再停/重启 bridge」的 detached supervisor（P18）。
 *
 * 由 `npm run restart -- --when-idle` / `npm run stop -- --when-idle` 拉起：
 * 它不是任何命令的子进程，bridge 退出时不会被一起带走；轮询登记目录直到没有
 * 活着的命令，再调用 `stop.mjs` 走正常的「先回写、再杀、再拉起」流程。
 *
 * 为什么要绕这一层：bridge 拉起的 cline 子进程用管道接 stdout/stderr，
 * bridge 一退出管道就断，会话会在十几秒内 exit 1（2026-11-02 12:24 实测）。
 * 所以在命令里重启 = 掐断发起命令的会话；把重启推迟到命令结束后才安全。
 *
 * 用法（一般不直接调，走 stop.mjs）：
 *   node scripts/restart-when-idle.mjs --reason "..." [--timeout 7200000] [--stop-only]
 */

const args = process.argv.slice(2)

function flag(name, fallback = '') {
  const index = args.indexOf(name)
  return index >= 0 ? args[index + 1] : fallback
}

const reason = String(flag('--reason', 'manual restart')).trim() || 'manual restart'
const timeoutMs = Number(flag('--timeout', 2 * 60 * 60 * 1000)) || 2 * 60 * 60 * 1000
const pollMs = Number(flag('--poll', 1000)) || 1000
/** 空闲后的缓冲：刚跑完一条命令，用户可能立刻再下发一条，别在这个缝隙里重启。 */
const graceMs = Number(flag('--grace', 3000)) || 3000
const stopOnly = args.includes('--stop-only')
const logFile = path.join(bridgeRoot, 'logs', 'restart-when-idle.log')
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

function log(message, extra) {
  const line = `${new Date().toISOString()} ${message}${extra ? ` ${JSON.stringify(extra)}` : ''}`
  try {
    fs.mkdirSync(path.dirname(logFile), { recursive: true })
    fs.appendFileSync(logFile, `${line}\n`, 'utf8')
  } catch {}
  console.log(line)
}

// 连点两次 `--when-idle` 时只保留一个 supervisor（另一个 bridge 起来后会找不到端口）。
const existing = readSupervisorLock()
if (existing) {
  let alive = false
  try {
    alive = isSupervisorAlive(existing, inspectProcesses([Number(existing.pid)]))
  } catch {}
  if (alive) {
    log('another supervisor already queued, skip', { pid: existing.pid, reason: existing.reason })
    process.exit(0)
  }
}

const lock = { pid: process.pid, startedAt: new Date().toISOString(), reason, stopOnly }
writeSupervisorLock(undefined, lock)

let lastLogAt = 0
try {
  log('waiting for in-flight commands', { reason, stopOnly, timeoutMs, pollMs })
  let result = { ok: false, waitedMs: 0, remaining: [] }
  for (;;) {
    result = await waitForIdle({
      readEntries: () => readEntries(registryDir()),
      inspectProcesses,
      timeoutMs,
      pollMs,
      onTick: ({ live, waitedMs, error }) => {
        const now = Date.now()
        if (now - lastLogAt < 30000 && !error) return
        lastLogAt = now
        log('still busy', {
          waitedMs,
          commands: live.map((entry) => entry.commandId),
          ...(error ? { error } : {})
        })
      }
    })
    if (!result.ok || graceMs <= 0) break

    log('idle, waiting grace before restart', { graceMs })
    await sleep(graceMs)
    // 缓冲结束再确认一次：这 3 秒里可能又来了新命令。
    const recheck = await waitForIdle({
      readEntries: () => readEntries(registryDir()),
      inspectProcesses,
      timeoutMs: 0
    })
    if (!recheck.ok) {
      log('new command during grace, keep waiting', { commands: recheck.remaining })
      continue
    }
    break
  }

  if (!result.ok) {
    log('timeout, bridge left untouched', result)
    process.exitCode = 1
  } else {
    log('idle, handing over to stop.mjs', { waitedMs: result.waitedMs })
    const stopArgs = [
      path.join(bridgeRoot, 'scripts', 'stop.mjs'),
      ...(stopOnly ? [] : ['--restart']),
      '--reason',
      `${reason}（等命令跑完）`
    ]
    const child = spawn(process.execPath, stopArgs, {
      cwd: bridgeRoot,
      detached: true,
      stdio: 'ignore',
      windowsHide: true,
      env: process.env
    })
    child.unref()
    log('stop/restart spawned', { pid: child.pid ?? null, stopOnly })
  }
} catch (error) {
  log('supervisor failed', { message: error.message })
  process.exitCode = 1
} finally {
  removeSupervisorLock(undefined, process.pid)
}
