import assert from 'node:assert/strict'
import test from 'node:test'

import { HttpError } from '../src/http.js'
import { createClientRoutes } from '../src/routes/clients.js'

const logger = { info() {}, warn() {}, error() {}, debug() {} }
const device = { id: 'localone', role: 'device' }
const app = { id: 'phone', role: 'app' }

function pick(routes, pattern) {
  const route = routes.find((item) => item.pattern === pattern && item.method === 'GET')
  assert.ok(route, `GET ${pattern} not found`)
  return route
}

/** 记录 SQL 与参数的最小 db 替身。 */
function capture(rows = []) {
  const calls = []
  const db = {
    async many(sql, params) {
      calls.push({ kind: 'many', sql: String(sql), params })
      return rows
    },
    async one() {
      throw new Error('unexpected one()')
    }
  }
  return { calls, db }
}

const row = {
  id: 'localone',
  name: 'LocalOne-Windows',
  created_at: '2026-11-01T00:00:00.000Z',
  last_seen_at: '2026-11-02T05:00:00.000Z',
  session_count: 12,
  command_count: 4,
  pending_commands: 1,
  running_commands: 2,
  last_session_at: '2026-11-02T04:59:00.000Z',
  last_command_at: '2026-11-02T04:58:00.000Z'
}

test('设备列表：app 能看到全部电脑端，且只查 role=device', async () => {
  const { calls, db } = capture([row])
  const route = pick(createClientRoutes({ db, logger }), '/api/v1/devices')

  const result = await route.handler({ client: app })

  assert.match(calls[0].sql, /c\.role = 'device'/)
  assert.doesNotMatch(calls[0].sql, /c\.id = \$1/)
  assert.deepEqual(calls[0].params, [])
  assert.deepEqual(result.items, [
    {
      id: 'localone',
      name: 'LocalOne-Windows',
      createdAt: '2026-11-01T00:00:00.000Z',
      lastSeenAt: '2026-11-02T05:00:00.000Z',
      sessionCount: 12,
      commandCount: 4,
      pendingCommands: 1,
      runningCommands: 2,
      lastSessionAt: '2026-11-02T04:59:00.000Z',
      lastCommandAt: '2026-11-02T04:58:00.000Z'
    }
  ])
})

test('设备列表：device token 只看自己（ADR-43 读隔离）', async () => {
  const { calls, db } = capture([row])
  const route = pick(createClientRoutes({ db, logger }), '/api/v1/devices')

  await route.handler({ client: device })

  assert.match(calls[0].sql, /c\.role = 'device' and c\.id = \$1/)
  assert.deepEqual(calls[0].params, ['localone'])
})

test('设备列表：没带 token 直接 401，不查库', async () => {
  const { calls, db } = capture()
  const route = pick(createClientRoutes({ db, logger }), '/api/v1/devices')

  await assert.rejects(
    route.handler({ client: null }),
    (error) => error instanceof HttpError && error.status === 401 && error.code === 'unauthorized'
  )
  assert.equal(calls.length, 0)
})
