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
  finished_at: null,
  cancel_requested_at: null
}

function patchHarness(updated, existing = baseRow) {
  const calls = []
  const db = {
    async one(sql, params) {
      calls.push({ sql, params })
      return String(sql).trimStart().startsWith('select') ? existing : updated
    }
  }
  const routes = createCommandRoutes({
    db,
    logger: { info() {}, warn() {}, error() {} },
    sse: { broadcast() {} }
  })
  return { route: routes.find((item) => item.method === 'PATCH'), calls }
}

function cancelHarness(existing, updated) {
  const calls = []
  const db = {
    async one(sql, params) {
      calls.push({ sql, params })
      return String(sql).trimStart().startsWith('select') ? existing : updated
    }
  }
  const routes = createCommandRoutes({
    db,
    logger: { info() {}, warn() {}, error() {} },
    sse: { broadcast() {} }
  })
  return { route: routes.find((item) => item.pattern === '/api/v1/commands/:id/cancel'), calls }
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

test('取消排队中的命令：直接 cancelled，不再等 bridge', async () => {
  const existing = { ...baseRow, status: 'delivered' }
  const updated = {
    ...existing,
    status: 'cancelled',
    error_text: '已取消：手机端在命令开始前取消。',
    finished_at: new Date('2026-11-02T03:05:00.000Z'),
    cancel_requested_at: new Date('2026-11-02T03:05:00.000Z')
  }
  const { route, calls } = cancelHarness(existing, updated)

  const result = await route.handler({ params: { id: baseRow.id }, client: device })

  assert.equal(result.command.status, 'cancelled')
  assert.equal(result.command.cancelRequestedAt.toISOString(), '2026-11-02T03:05:00.000Z')
  assert.equal(calls.length, 2)
  assert.deepEqual(calls[1].params, [baseRow.id])
})

test('取消执行中的命令：置 cancelling，等 bridge 杀进程后回写 cancelled', async () => {
  const existing = { ...baseRow, status: 'running', started_at: '2026-11-02T03:00:05.000Z' }
  const updated = {
    ...existing,
    status: 'cancelling',
    cancel_requested_at: new Date('2026-11-02T03:06:00.000Z')
  }
  const { route } = cancelHarness(existing, updated)

  const result = await route.handler({ params: { id: baseRow.id }, client: device })

  assert.equal(result.command.status, 'cancelling')
  assert.equal(result.command.finishedAt, null)
})

test('取消已经结束的命令返回 409，不覆盖结果', async () => {
  const existing = { ...baseRow, status: 'done', finished_at: '2026-11-02T03:10:00.000Z' }
  const { route, calls } = cancelHarness(existing, existing)

  await assert.rejects(
    route.handler({ params: { id: baseRow.id }, client: device }),
    (error) => error instanceof HttpError && error.status === 409 && error.code === 'already_finished'
  )
  assert.equal(calls.length, 1) // 只做了 select，没有 update
})

test('已取消的命令收到 running / done 一律忽略（防止取消被翻回成功）', async () => {
  const existing = { ...baseRow, status: 'cancelled', cancel_requested_at: new Date() }
  const { route, calls } = patchHarness(existing, existing)

  const result = await route.handler({
    params: { id: baseRow.id },
    body: { status: 'done', resultText: '看起来成功了' },
    client: device
  })

  assert.equal(result.ignored, true)
  assert.equal(result.command.status, 'cancelled')
  assert.equal(calls.length, 1)
})

test('cancelling 期间 bridge 补报 running（pid / sessionId）不会把状态翻回去', async () => {
  const existing = { ...baseRow, status: 'cancelling' }
  const { route, calls } = patchHarness(existing, existing)

  await route.handler({
    params: { id: baseRow.id },
    body: { status: 'running', pid: 99, runner: 'cline' },
    client: device
  })

  assert.equal(calls[1].params[1], 'cancelling')
  assert.equal(calls[1].params[5], 99)
})
