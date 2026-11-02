import assert from 'node:assert/strict'
import test from 'node:test'

import { toRecord, workspaceName, sessionState, fingerprintOf } from '../src/record.js'

const extraction = {
  ok: true,
  reason: null,
  resultText: 'done',
  resultTruncated: false,
  userPrompt: '把测试跑一遍',
  commands: [],
  metrics: { commandCount: 0 }
}

const row = {
  session_id: '1791744249853_in12x',
  source: 'cli',
  status: 'completed',
  exit_code: 0,
  provider: 'cline',
  model: 'deepseek-flash',
  cwd: 'C:/Users/alice/.cline/data/workspaces/chat/cline-hub',
  workspace_root: 'C:/Users/alice/.cline/data/workspaces/chat/cline-hub/',
  prompt: 'raw prompt',
  started_at: '2026-11-02T01:00:00.000Z',
  ended_at: '2026-11-02T01:05:00.000Z',
  updated_at: '2026-11-02T01:05:00.000Z'
}

test('workspaceName 去掉分隔符尾部再取末段', () => {
  assert.equal(workspaceName('C:\\a\\b\\'), 'b')
  assert.equal(workspaceName('C:/a/b'), 'b')
  assert.equal(workspaceName(''), '')
  assert.equal(workspaceName(null), '')
})

test('toRecord 带出项目识别字段（重发靠它补 project*）', () => {
  const record = toRecord(row, extraction)
  assert.equal(record.sessionId, row.session_id)
  assert.equal(record.workspace, 'cline-hub')
  // 正斜杠 / 反斜杠都指向同一个带 .git 的目录
  assert.equal(record.project, 'cline-hub')
  assert.equal(record.projectKind, 'project')
  assert.ok(record.projectRoot)
  assert.equal(record.resultText, 'done')
  assert.equal(record.userPrompt, '把测试跑一遍')
})

test('toRecord 在 messages 缺失时退回 sessions.prompt', () => {
  const failed = { ...extraction, ok: false, reason: 'missing', resultText: '', userPrompt: '' }
  const record = toRecord(row, failed)
  assert.equal(record.resultOk, false)
  assert.equal(record.resultError, 'missing')
  assert.equal(record.userPrompt, 'raw prompt')
})

test('sessionState 把「running 但进程已死」判成僵尸失败', () => {
  // pid 999999 基本不可能存在；存在也只是让这个用例变成 running，不会误判成 failed
  const alive = sessionState({ status: 'running', pid: process.pid })
  assert.equal(alive.status, 'running')
  assert.equal(alive.zombie, false)

  const zombie = sessionState({ status: 'running', pid: 4_000_000 })
  assert.equal(zombie.status, 'failed')
  assert.equal(zombie.zombie, true)

  // failed 但没有 ended_at：cline 在跑的时候会短暂写成 failed
  assert.equal(sessionState({ status: 'failed', ended_at: null }).status, 'running')
})

test('fingerprintOf 只看 status + updated_at', () => {
  assert.equal(
    fingerprintOf({ status: 'completed', updated_at: '2026-11-02T01:05:00.000Z' }),
    'completed|2026-11-02T01:05:00.000Z'
  )
})
