import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'

import {
  PID_START_TOLERANCE_MS,
  entryPath,
  readEntries,
  readEntry,
  registryDir,
  removeEntry,
  sameProcessStart,
  writeEntry
} from '../src/command-registry.js'

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'cline-hub-reg-'))
}

const entry = (id, extra = {}) => ({
  commandId: id,
  pid: 4242,
  pidStartedAt: '2026-11-02T03:00:00.000Z',
  workspace: 'C:\\Users\\alice\\.cline\\data\\workspaces\\chat\\cline-hub',
  mode: 'act',
  runner: 'cline',
  bridgePid: 999,
  executable: 'node cline',
  startedAt: '2026-11-02T03:00:00.000Z',
  ...extra
})

test('登记表读写：写入后可读回，按 startedAt 升序，删除后为空', () => {
  const dir = tempDir()
  writeEntry(dir, entry('cmd_b', { startedAt: '2026-11-02T03:00:02.000Z' }))
  writeEntry(dir, entry('cmd_a'))

  const entries = readEntries(dir)
  assert.deepEqual(entries.map((item) => item.commandId), ['cmd_a', 'cmd_b'])
  assert.equal(readEntry(dir, 'cmd_a').pid, 4242)
  assert.equal(readEntry(dir, 'cmd_missing'), null)

  assert.equal(removeEntry(dir, 'cmd_a'), true)
  assert.equal(removeEntry(dir, 'cmd_a'), false)
  assert.deepEqual(readEntries(dir).map((item) => item.commandId), ['cmd_b'])
})

test('commandId 会被洗成安全文件名，拼不出目录穿越', () => {
  const dir = tempDir()
  const file = writeEntry(dir, entry('..\\..\\evil'))
  assert.equal(path.dirname(file), dir)
  assert.ok(path.basename(file).startsWith('______evil.json'))
  assert.equal(readEntry(dir, '..\\..\\evil').pid, 4242)
})

test('坏掉的登记文件被跳过，不影响其他命令', () => {
  const dir = tempDir()
  writeEntry(dir, entry('cmd_ok'))
  fs.writeFileSync(path.join(dir, 'cmd_broken.json'), '{ not json', 'utf8')
  assert.deepEqual(readEntries(dir).map((item) => item.commandId), ['cmd_ok'])
})

test('默认登记目录在临时目录的 cline-hub-cmd/running 下', () => {
  assert.equal(registryDir('C:\\temp').replaceAll('\\', '/'), 'C:/temp/cline-hub-cmd/running')
  assert.equal(entryPath('C:\\temp', 'cmd_x').replaceAll('\\', '/'), 'C:/temp/cmd_x.json')
})

test('双校验：pid 与启动时间都对上才算同一条命令', () => {
  const start = Date.parse('2026-11-02T03:00:00.000Z')
  const row = entry('cmd_a')
  assert.equal(sameProcessStart(row, { pid: 4242, startedAtMs: start }), true)
  // spawn 返回后取时间的毫秒级误差
  assert.equal(sameProcessStart(row, { pid: 4242, startedAtMs: start + 120 }), true)
  // 超出容差 = PID 已被复用
  assert.equal(sameProcessStart(row, { pid: 4242, startedAtMs: start + PID_START_TOLERANCE_MS + 1 }), false)
  // pid 不同 / 进程不在 / 没记启动时间
  assert.equal(sameProcessStart(row, { pid: 4243, startedAtMs: start }), false)
  assert.equal(sameProcessStart(row, null), false)
  assert.equal(sameProcessStart(entry('cmd_a', { pidStartedAt: null }), { pid: 4242, startedAtMs: start }), false)
  assert.equal(sameProcessStart(row, { pid: 4242, startedAtMs: 0 }), false)
})
