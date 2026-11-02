import assert from 'node:assert/strict'
import test from 'node:test'

import { HttpError } from '../src/http.js'
import { createCommandRoutes } from '../src/routes/commands.js'

const baseRow = {
  id: 'cmd_abc123',
  device_id: 'localone',
  prompt: '跑一遍测试',
  mode: 'act',
  workspace: 'C:\\Users\\alice\\.cline\\data\\workspaces\\chat\\cline-hub',
  session_id: null,
  status: 'delivered',
  requested_by: 'phone',
  runner: null,
  pid: null,
  pid_started_at: null,
  result_text: null,
  error_text: null,
  created_at: '2026-11-02T03:00:00.000Z',
  delivered_at: '2026-11-02T03:00:01.000Z',
  started_at: null,
  finished_at: null
}

function patchHarness(updated) {
  const calls = []
  const db = {
    async one(sql, params) {
      calls.push({ sql, params })
      return String(sql).trimStart().startsWith('select') ? baseRow : updated
    }
  }
  const routes = createCommandRoutes({
    db,
    logger: { info() {}, warn() {}, error() {} },
    sse: { broadcast() {} }
  })
  return { route: routes.find((item) => item.method === 'PATCH'), calls }
}

const device = { role: 'device', id: 'localone' }

test('PATCH 接收 pid / pidStartedAt / runner 并写进 update 参数', async () => {
  const updated = {
    ...baseRow,
    status: 'running',
    pid: 4242,
    pid_started_at: new Date('2026-11-02T03:00:05.000Z'),
    runner: 'cline'
  }
  const { route, calls } = patchHarness(updated)
  const result = await route.handler({
    params: { id: baseRow.id },
    body: {
      status: 'running',
      pid: 4242,
      pidStartedAt: '2026-11-02T03:00:05.000Z',
      runner: 'cline'
    },
    client: device
  })

  assert.equal(calls.length, 2)
  assert.deepEqual(calls[1].params, [
    baseRow.id,
    'running',
    null,
    null,
    null,
    4242,
    '2026-11-02T03:00:05.000Z',
    'cline'
  ])
  assert.equal(result.command.pid, 4242)
  assert.equal(result.command.runner, 'cline')
  assert.equal(result.command.pidStartedAt.toISOString(), '2026-11-02T03:00:05.000Z')
})

test('pid 传字符串也接受（JSON 客户端常见）', async () => {
  const { route, calls } = patchHarness({ ...baseRow, pid: 88 })
  await route.handler({
    params: { id: baseRow.id },
    body: { status: 'running', pid: '88' },
    client: device
  })
  assert.equal(calls[1].params[5], 88)
})

test('非法 pid 直接 400，不落库', async () => {
  const { route, calls } = patchHarness(baseRow)
  await assert.rejects(
    route.handler({
      params: { id: baseRow.id },
      body: { status: 'running', pid: 'abc' },
      client: device
    }),
    (error) => error instanceof HttpError && error.status === 400 && error.code === 'invalid_field'
  )
  assert.equal(calls.length, 1) // 只做了 select，没有 update
})

test('没有进程字段时全部写 null，旧 bridge 仍然兼容', async () => {
  const { route, calls } = patchHarness({ ...baseRow, status: 'done' })
  await route.handler({
    params: { id: baseRow.id },
    body: { status: 'done', resultText: 'ok' },
    client: device
  })
  assert.deepEqual(calls[1].params, [baseRow.id, 'done', 'ok', null, null, null, null, null])
})
