#!/usr/bin/env node
/**
 * 本机命令进程表：App 里的哪条命令对应哪个进程、还活着吗、安全杀法是什么。
 *
 *   npm run ps                     表格
 *   npm run ps -- --json           机器可读（脚本/排障用）
 *   npm run ps -- --kill <id>      只杀这一条（先双校验，对不上就拒绝）
 *   npm run ps -- --clean          清掉已退出命令的登记文件
 *
 * 判定规则见 `src/command-registry.js`：pid + 进程启动时间（±5s）。
 * 只对上 pid 一律当作「PID 可能被复用」，**拒绝 kill** —— Windows 的 PID 会复用，
 * 按 pid 盲杀可能误伤无关进程（例如刚启动的编辑器）。
 */
import { spawnSync } from 'node:child_process'

import {
  PID_START_TOLERANCE_MS,
  readEntries,
  readEntry,
  registryDir,
  removeEntry,
  sameProcessStart
} from '../src/command-registry.js'
import { inspectProcesses } from '../src/process-info.js'

const args = process.argv.slice(2)
const asJson = args.includes('--json')
const doClean = args.includes('--clean')
const killIndex = args.indexOf('--kill')
const killId = killIndex >= 0 ? args[killIndex + 1] : null
const dir = registryDir()

if (killIndex >= 0 && !killId) {
  console.error('用法：npm run ps -- --kill <commandId>（commandId 见 `npm run ps` 第一列）')
  process.exit(1)
}

function shortPath(value, max = 46) {
  const text = String(value ?? '')
  if (text.length <= max) return text
  return `…${text.slice(-(max - 1))}`
}

const entries = readEntries(dir)
const processes = inspectProcesses(entries.flatMap((entry) => [Number(entry.pid), Number(entry.bridgePid)]))

const rows = entries.map((entry) => {
  const info = processes.get(Number(entry.pid)) ?? null
  const alive = Boolean(info)
  const verified = sameProcessStart(entry, info)
  const bridgeAlive = Boolean(processes.get(Number(entry.bridgePid)))
  return { entry, info, alive, verified, bridgeAlive }
})

if (killId) {
  const entry = readEntry(dir, killId)
  if (!entry) {
    console.error(`✗ 没有 ${killId} 的登记（可能已经退出，或 commandId 拼错）`)
    process.exit(1)
  }
  const info = inspectProcesses([Number(entry.pid)]).get(Number(entry.pid)) ?? null
  if (!info) {
    console.error(`✗ ${entry.commandId} 的进程 ${entry.pid} 已经不在了，无需 kill`)
    process.exit(1)
  }
  if (!sameProcessStart(entry, info)) {
    console.error(`✗ 双校验不通过：pid ${entry.pid} 现在是 ${info.name || '另一个进程'}，启动时间与登记不符`)
    console.error('  Windows 复用了这个 PID，按 pid 杀会误伤。请执行 `npm run ps -- --clean` 清掉这条登记。')
    process.exit(1)
  }
  const killed = process.platform === 'win32'
    ? spawnSync('taskkill', ['/pid', String(entry.pid), '/t', '/f'], { windowsHide: true, encoding: 'utf8' })
    : spawnSync('kill', ['-9', String(entry.pid)], { encoding: 'utf8' })
  if (killed.status !== 0) {
    console.error(`✗ kill 失败：${(killed.stderr || killed.stdout || '').trim() || `exit ${killed.status}`}`)
    process.exit(1)
  }
  removeEntry(dir, entry.commandId)
  console.log(`✓ 已终止 ${entry.commandId}（pid ${entry.pid}，进程树）`)
  process.exit(0)
}

if (doClean) {
  const stale = rows.filter((row) => !row.alive || !row.verified)
  for (const row of stale) removeEntry(dir, row.entry.commandId)
  console.log(`✓ 清理 ${stale.length} 条登记${stale.length ? '：' + stale.map((row) => row.entry.commandId).join(', ') : ''}`)
  process.exit(0)
}

if (asJson) {
  console.log(JSON.stringify({
    ok: true,
    registry: dir,
    pidStartToleranceMs: PID_START_TOLERANCE_MS,
    items: rows.map(({ entry, info, alive, verified, bridgeAlive }) => ({
      commandId: entry.commandId,
      pid: entry.pid ?? null,
      pidStartedAt: entry.pidStartedAt ?? null,
      alive,
      verified,
      workspace: entry.workspace ?? null,
      mode: entry.mode ?? null,
      runner: entry.runner ?? null,
      bridgePid: entry.bridgePid ?? null,
      bridgeAlive,
      processName: info?.name ?? null
    }))
  }, null, 2))
  process.exit(0)
}

if (rows.length === 0) {
  console.log('没有正在执行的远程命令。')
  console.log(`登记目录：${dir}`)
  process.exit(0)
}

console.log(`登记目录：${dir}`)
console.log('')
console.log('COMMANDID           PID      状态     双校验  工作目录 / 说明')
for (const { entry, info, alive, verified, bridgeAlive } of rows) {
  const status = alive ? '执行中' : '已退出'
  const check = !alive ? '—' : verified ? '✓' : '✗'
  const extra = alive
    ? `${shortPath(entry.workspace)}${bridgeAlive ? '' : '（bridge 已退出 → 孤儿进程）'}`
    : '进程已不在，可 --clean'
  console.log(
    `${String(entry.commandId).padEnd(19)} ${String(entry.pid ?? '-').padEnd(8)} ${status.padEnd(8)} ${check.padEnd(6)} ${extra}`
  )
  if (alive && verified) console.log(`  kill：taskkill /pid ${entry.pid} /t /f    或 npm run ps -- --kill ${entry.commandId}`)
  if (alive && !verified) console.log(`  注意：pid ${entry.pid} 已被 ${info?.name ?? '另一个进程'} 复用，禁止按 pid 杀`)
}

console.log('')
console.log(`双校验 = pid + 启动时间（±${PID_START_TOLERANCE_MS / 1000}s）。`)
console.log('清理已退出/被复用的登记：npm run ps -- --clean')
