import assert from 'node:assert/strict'
import test from 'node:test'

import {
  ORPHAN_GRACE_MS,
  classifyRunningCommand,
  processLiveness
} from '../src/command-registry.js'

const NOW = Date.parse('2026-11-02T04:10:00.000Z')
const minutesAgo = (minutes) => new Date(NOW - minutes * 60 * 1000).toISOString()
const entry = (extra = {}) => ({
  commandId: 'cmd_old',
  pid: 4242,
  pidStartedAt: minutesAgo(30),
  ...extra
})

test('running 的命令：本进程在跑就不动', () => {
  assert.equal(
    classifyRunningCommand({
      command: { startedAt: minutesAgo(30) },
      entry: entry(),
      alive: true,
      verified: true,
      owned: true,
      nowMs: NOW
    }),
    'owned'
  )
})

test('刚领取 / 时间戳缺失的命令留在观察期，不判死', () => {
  const recent = classifyRunningCommand({
    command: { startedAt: minutesAgo(1) },
    entry: null,
    nowMs: NOW
  })
  assert.equal(recent, 'recent')
  assert.equal(ORPHAN_GRACE_MS, 120000)

  // 老数据可能没有 startedAt（例如加字段之前的命令），createdAt 也缺 → 宁可不动
  assert.equal(
    classifyRunningCommand({ command: {}, entry: null, nowMs: NOW }),
    'recent'
  )
})

test('过了观察期且本机没有登记 → 孤儿', () => {
  assert.equal(
    classifyRunningCommand({
      command: { startedAt: minutesAgo(15), createdAt: minutesAgo(15) },
      entry: null,
      alive: false,
      verified: false,
      nowMs: NOW
    }),
    'orphaned'
  )
})

test('登记还在、进程也活着且启动时间对得上 → 不动（可能是上一个 bridge 进程）', () => {
  assert.equal(
    classifyRunningCommand({
      command: { startedAt: minutesAgo(30) },
      entry: entry(),
      alive: true,
      verified: true,
      nowMs: NOW
    }),
    'alive'
  )
})

test('pid 还在但启动时间对不上（被复用）→ 孤儿', () => {
  assert.equal(
    classifyRunningCommand({
      command: { startedAt: minutesAgo(30) },
      entry: entry(),
      alive: true,
      verified: false,
      nowMs: NOW
    }),
    'orphaned'
  )
})

test('processLiveness：没有登记 / 进程不在 / 拿到启动时间 / 拿不到启动时间', () => {
  assert.deepEqual(processLiveness(null, new Map()), { alive: false, verified: false })
  assert.deepEqual(
    processLiveness({ pid: 4242 }, new Map()),
    { alive: false, verified: false }
  )

  const started = Date.parse(minutesAgo(30))
  const processes = new Map([[4242, { pid: 4242, startedAtMs: started }]])
  assert.deepEqual(processLiveness(entry(), processes), { alive: true, verified: true })

  // 非 Windows 的 startedAtMs 恒为 0：只能确认 pid 存在，按「活着」处理，不判死
  assert.deepEqual(
    processLiveness(entry(), new Map([[4242, { pid: 4242, startedAtMs: 0 }]])),
    { alive: true, verified: true }
  )

  // 同一个 pid 现在对应另一个启动时间的进程 → 原命令的进程已经没了
  assert.deepEqual(
    processLiveness(entry(), new Map([[4242, { pid: 4242, startedAtMs: started + 60_000 }]])),
    { alive: true, verified: false }
  )
})
