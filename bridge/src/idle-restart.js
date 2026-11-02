import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

import { processLiveness, sameProcessStart } from './command-registry.js'

/**
 * 「等命令跑完再重启 bridge」的核心逻辑（P18）。
 *
 * 为什么不是直接在命令里重启（2026-11-02 12:24 事故）：
 * bridge 拉起的 cline 子进程用 `stdio: ['ignore','pipe','pipe']`，bridge 一退出，
 * 管道就断，cline 十几秒后自己 exit 1 —— `--keep-session` 只保住进程、保不住会话，
 * 发起重启的那轮对话直接断在半路（`cmd_c4a49f60fccf` / session `1793593493423_cc793`）。
 *
 * 做法：重启请求交给一个 detached supervisor（不属于任何命令的进程树），
 * 它轮询本机登记目录，等「还活着的命令」清零后再调用 `stop.mjs --restart`。
 * 这样当前会话可以正常跑完，下一次手机命令才落到新 bridge 上。
 */

/** 登记目录里还活着的命令（pid 存在，且启动时间对得上；pid 被复用不算）。 */
export function liveCommandEntries(entries, processes) {
  return (Array.isArray(entries) ? entries : []).filter((entry) => {
    const liveness = processLiveness(entry, processes)
    return liveness.alive && liveness.verified
  })
}

/**
 * 等到没有活着的命令。
 *
 * `readEntries` / `inspectProcesses` / `sleep` 都注入，便于测试；
 * 查询失败（PowerShell 偶发异常）时按「还在忙」处理，宁可多等也不误重启。
 */
export async function waitForIdle({
  readEntries,
  inspectProcesses,
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  timeoutMs = 2 * 60 * 60 * 1000,
  pollMs = 1000,
  onTick
} = {}) {
  const startedAt = Date.now()
  let lastError = null
  for (;;) {
    let live = []
    try {
      const entries = readEntries()
      const pids = entries.map((entry) => entry.pid).filter(Boolean)
      live = liveCommandEntries(entries, inspectProcesses(pids))
      lastError = null
    } catch (error) {
      // 查不清就先别动 bridge；把错误交给调用方记日志。
      lastError = error
    }

    const waitedMs = Date.now() - startedAt
    if (!live.length && !lastError) return { ok: true, waitedMs, remaining: [] }
    if (waitedMs >= timeoutMs) {
      return {
        ok: false,
        waitedMs,
        remaining: live.map((entry) => entry.commandId),
        ...(lastError ? { error: lastError.message } : {})
      }
    }
    onTick?.({ live, waitedMs, ...(lastError ? { error: lastError.message } : {}) })
    await sleep(pollMs)
  }
}

/** supervisor 的锁文件：防止用户连点两次 `--when-idle` 排出两个 restart。 */
export function supervisorLockPath(baseDir = os.tmpdir()) {
  return path.join(baseDir, 'cline-hub-cmd', 'restart-when-idle.json')
}

export function readSupervisorLock(baseDir = os.tmpdir()) {
  try {
    return JSON.parse(fs.readFileSync(supervisorLockPath(baseDir), 'utf8'))
  } catch {
    return null
  }
}

export function writeSupervisorLock(baseDir = os.tmpdir(), lock = {}) {
  const file = supervisorLockPath(baseDir)
  fs.mkdirSync(path.dirname(file), { recursive: true })
  fs.writeFileSync(file, `${JSON.stringify(lock, null, 2)}\n`, 'utf8')
  return file
}

export function removeSupervisorLock(baseDir = os.tmpdir(), pid = process.pid) {
  try {
    const lock = readSupervisorLock(baseDir)
    if (lock && Number(lock.pid) !== Number(pid)) return false
    fs.unlinkSync(supervisorLockPath(baseDir))
    return true
  } catch {
    return false
  }
}

/**
 * 锁里的 supervisor 还活着吗？
 * 锁里存的是自己写文件的墙钟时间，和 Windows CreationDate 有秒级误差，沿用 5 秒容差。
 */
export function isSupervisorAlive(lock, processes) {
  if (!lock?.pid) return false
  const info = processes instanceof Map
    ? processes.get(Number(lock.pid))
    : processes?.[Number(lock.pid)]
  return sameProcessStart({ pid: lock.pid, pidStartedAt: lock.startedAt }, info)
}
