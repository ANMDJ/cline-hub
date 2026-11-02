import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

/**
 * 远程命令的本机进程登记表。
 *
 * Hub 上的 `pid` 只是展示与排障线索；真正决定「能不能杀」的是本机这份登记：
 * 每条命令 spawn 成功时落一个 `<commandId>.json`，记下 pid + 进程启动时间。
 * Windows 会复用 PID，所以 kill 之前必须两项都对上；只对上 pid 一律拒绝
 * （否则 bridge 重启后可能杀掉一个恰好拿到旧 pid 的无关进程）。
 *
 * 放在 `%TEMP%\cline-hub-cmd\running\`，不进仓库、不写日志；正常结束就删掉。
 * bridge 崩溃遗留的文件由 `npm run ps -- --clean` 收拾。
 */

/** spawn 时刻与 Windows CreationDate 的正常误差远小于这个值。 */
export const PID_START_TOLERANCE_MS = 5000

export function registryDir(baseDir = os.tmpdir()) {
  return path.join(baseDir, 'cline-hub-cmd', 'running')
}

/**
 * commandId 来自服务端（`cmd_<hex>`）。这里再洗一次，避免任何情况下
 * 拼出 `..\..\` 之类的路径；洗掉字符后的名字仍然稳定（同一个 id 总落到同一个文件）。
 */
export function entryPath(dir, commandId) {
  const safe = String(commandId).replace(/[^A-Za-z0-9_-]/g, '_')
  return path.join(dir, `${safe}.json`)
}

export function writeEntry(dir, entry) {
  fs.mkdirSync(dir, { recursive: true })
  const file = entryPath(dir, entry.commandId)
  // 先写临时文件再 rename：ps.mjs 并发读时不会读到半截 JSON。
  const tmp = `${file}.${process.pid}.tmp`
  fs.writeFileSync(tmp, `${JSON.stringify(entry, null, 2)}\n`, 'utf8')
  fs.renameSync(tmp, file)
  return file
}

/** 登记目录里所有可解析的条目；坏文件直接跳过（不该让 ps 整体失败）。 */
export function readEntries(dir) {
  let names = []
  try {
    names = fs.readdirSync(dir).filter((name) => name.endsWith('.json'))
  } catch {
    return []
  }
  const entries = []
  for (const name of names) {
    try {
      const entry = JSON.parse(fs.readFileSync(path.join(dir, name), 'utf8'))
      if (entry && entry.commandId) entries.push(entry)
    } catch {}
  }
  return entries.sort((a, b) => String(a.startedAt ?? '').localeCompare(String(b.startedAt ?? '')))
}

export function readEntry(dir, commandId) {
  try {
    return JSON.parse(fs.readFileSync(entryPath(dir, commandId), 'utf8'))
  } catch {
    return null
  }
}

export function removeEntry(dir, commandId) {
  try {
    fs.unlinkSync(entryPath(dir, commandId))
    return true
  } catch {
    return false
  }
}

/**
 * `pid + 启动时间` 双校验（纯函数，便于测试）。
 *
 * `processInfo.startedAtMs` 来自 `Get-CimInstance Win32_Process` 的 CreationDate；
 * 不到 1 秒的误差来自「spawn 返回后才取时间」，所以留 5 秒容差。
 * 缺启动时间一律判 false —— 宁可不杀，也不能猜。
 */
export function sameProcessStart(entry, processInfo, toleranceMs = PID_START_TOLERANCE_MS) {
  if (!entry || !processInfo) return false
  if (Number(entry.pid) !== Number(processInfo.pid)) return false
  const expected = Date.parse(String(entry.pidStartedAt ?? ''))
  const actual = Number(processInfo.startedAtMs)
  if (!Number.isFinite(expected) || !Number.isFinite(actual) || actual <= 0) return false
  return Math.abs(actual - expected) <= toleranceMs
}

/**
 * 登记 + 进程快照 → `{ alive, verified }`。
 *
 * 非 Windows 的 `startedAtMs` 恒为 0（拿不到 CreationDate）：只能确认 pid 存在，
 * 于是按「活着且可信」处理 —— 宁可少回收一条，也不能因为信息不足把还在跑的命令判死。
 */
export function processLiveness(entry, processes) {
  if (!entry || !entry.pid) return { alive: false, verified: false }
  const info = processes instanceof Map
    ? processes.get(Number(entry.pid))
    : processes?.[Number(entry.pid)]
  if (!info) return { alive: false, verified: false }
  const startedAtMs = Number(info.startedAtMs)
  if (!Number.isFinite(startedAtMs) || startedAtMs <= 0) return { alive: true, verified: true }
  return { alive: true, verified: sameProcessStart(entry, info) }
}

/**
 * 刚领取的 running 命令先留观，避免把「正在 spawn」误判成孤儿。
 * bridge 每 tick（5s）重建一次 Map，留 2 分钟足够覆盖启动慢的机器。
 */
export const ORPHAN_GRACE_MS = 2 * 60 * 1000

/**
 * Hub 上仍是 `running` 的命令，本机到底还有没有对应进程？
 *
 * 返回：
 *   'owned'    本进程正在跑（children 里有）
 *   'recent'   刚进入 running，留观期内不下结论
 *   'alive'    进程还在，且启动时间对得上（可能属于上一个 bridge 进程，本进程接管不了）
 *   'orphaned' 没有登记 / 进程已不在 / pid 已被复用 → 可以安全回写 failed
 *
 * 只有 'orphaned' 会被回写，**任何分支都不杀进程**（不盲杀，见 ADR-34）。
 */
export function classifyRunningCommand({
  command,
  entry,
  alive = false,
  verified = false,
  owned = false,
  nowMs = Date.now(),
  graceMs = ORPHAN_GRACE_MS
}) {
  if (owned) return 'owned'
  const started = Date.parse(String(command?.startedAt ?? command?.createdAt ?? ''))
  // 时间戳拿不到（老数据 / 字段缺失）时宁可不动：判错会造成「看起来失败、其实在跑」。
  if (!Number.isFinite(started) || Number(nowMs) - started < graceMs) return 'recent'
  if (entry && alive && verified) return 'alive'
  return 'orphaned'
}

