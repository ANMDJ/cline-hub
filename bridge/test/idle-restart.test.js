import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'

import {
  isSupervisorAlive,
  liveCommandEntries,
  readSupervisorLock,
  removeSupervisorLock,
  waitForIdle,
  writeSupervisorLock
} from '../src/idle-restart.js'

const START = '2026-11-02T03:00:00.000Z'
const entry = (id, pid, startedAt = START) => ({
  commandId: id,
  pid,
  pidStartedAt: startedAt
})

const processInfo = (pid, startedAt = START) => ({
  pid,
  startedAtMs: Date.parse(startedAt)
})

test('liveCommandEntries：只算 pid + 启动时间都对得上的命令', () => {
  const entries = [entry('cmd_a', 100), entry('cmd_b', 200), entry('cmd_c', 300)]
  const processes = new Map([
    [100, processInfo(100, '2026-11-02T03:00:01.000Z')], // 双校验通过
    [200, processInfo(200, '2026-11-02T05:00:00.000Z')], // pid 被复用
    [400, processInfo(400)] // 无关进程
  ])
  assert.deepEqual(liveCommandEntries(entries, processes).map((item) => item.commandId), ['cmd_a'])
})

test('liveCommandEntries：没有登记 / 空输入都返回空', () => {
  assert.deepEqual(liveCommandEntries([], new Map()), [])
  assert.deepEqual(liveCommandEntries(null, new Map()), [])
})

test('waitForIdle：没有命令时立刻返回', async () => {
  const result = await waitForIdle({
    readEntries: () => [],
    inspectProcesses: () => new Map(),
    sleep: async () => {},
    timeoutMs: 1000
  })
  assert.equal(result.ok, true)
  assert.deepEqual(result.remaining, [])
})

test('waitForIdle：等最后一条命令结束才返回', async () => {
  let calls = 0
  const result = await waitForIdle({
    readEntries: () => {
      calls += 1
      return calls < 3 ? [entry('cmd_busy', 100)] : []
    },
    inspectProcesses: () => new Map([[100, processInfo(100)]]),
    sleep: async () => {},
    timeoutMs: 10000,
    pollMs: 0
  })
  assert.equal(result.ok, true)
  assert.equal(calls, 3)
})

test('waitForIdle：超时返回仍在跑的命令，不误重启', async () => {
  const result = await waitForIdle({
    readEntries: () => [entry('cmd_busy', 100)],
    inspectProcesses: () => new Map([[100, processInfo(100)]]),
    sleep: async () => {},
    timeoutMs: 0
  })
  assert.equal(result.ok, false)
  assert.deepEqual(result.remaining, ['cmd_busy'])
})

test('waitForIdle：进程查询失败时按「还在忙」处理', async () => {
  const result = await waitForIdle({
    readEntries: () => {
      throw new Error('PowerShell 查询失败')
    },
    inspectProcesses: () => new Map(),
    sleep: async () => {},
    timeoutMs: 0
  })
  assert.equal(result.ok, false)
  assert.match(result.error, /PowerShell/)
  assert.deepEqual(result.remaining, [])
})

test('supervisor 锁：写入 / 读回 / 存活判断 / 只删自己的', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cline-hub-idle-'))
  writeSupervisorLock(dir, { pid: 4242, startedAt: START, reason: 'test' })

  const lock = readSupervisorLock(dir)
  assert.equal(lock.pid, 4242)
  assert.equal(lock.reason, 'test')

  assert.equal(isSupervisorAlive(lock, new Map([[4242, processInfo(4242, '2026-11-02T03:00:01.000Z')]])), true)
  assert.equal(isSupervisorAlive(lock, new Map()), false)
  assert.equal(isSupervisorAlive(null, new Map()), false)

  assert.equal(removeSupervisorLock(dir, 9999), false)
  assert.equal(removeSupervisorLock(dir, 4242), true)
  assert.equal(readSupervisorLock(dir), null)
})
