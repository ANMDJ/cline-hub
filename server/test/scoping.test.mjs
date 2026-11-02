import assert from 'node:assert/strict'
import test from 'node:test'

import { HttpError, createApp, createHttpServer, createSseChannel, sseMayReceive } from '../src/http.js'
import { createCommandRoutes } from '../src/routes/commands.js'
import { createHookRoutes } from '../src/routes/hooks.js'
import { createSessionRoutes } from '../src/routes/sessions.js'

const logger = { info() {}, warn() {}, error() {}, debug() {} }
const sse = { broadcast() {} }
const device = { id: 'localone', role: 'device' }
const app = { id: 'phone', role: 'app' }

const url = (path) => new URL(path, 'http://127.0.0.1:3100')

function pick(routes, pattern, method = 'GET') {
  const route = routes.find((item) => item.pattern === pattern && item.method === method)
  assert.ok(route, `${method} ${pattern} not found`)
  return route
}

/** 记录 SQL 与参数的最小 db 替身；查询一律返回空，只看接口拼出来的条件。 */
function capture(row = null) {
  const calls = []
  const db = {
    async many(sql, params) {
      calls.push({ kind: 'many', sql: String(sql), params })
      return []
    },
    async one(sql, params) {
      calls.push({ kind: 'one', sql: String(sql), params })
      return row
    }
  }
  return { calls, db }
}

test('会话列表：device token 自动锁定自己的 device_id', async () => {
  const { calls, db } = capture()
  const route = pick(createSessionRoutes({ db, logger, sse }), '/api/v1/sessions')

  await route.handler({ url: url('/api/v1/sessions?limit=10'), client: device })

  assert.match(calls[0].sql, /device_id = \$1/)
  assert.deepEqual(calls[0].params, ['localone', 11])
})

test('会话列表：device token 传别人的 deviceId 直接 403，不查库', async () => {
  const { calls, db } = capture()
  const route = pick(createSessionRoutes({ db, logger, sse }), '/api/v1/sessions')

  await assert.rejects(
    route.handler({ url: url('/api/v1/sessions?deviceId=other'), client: device }),
    (error) => error instanceof HttpError && error.status === 403 && error.code === 'device_mismatch'
  )
  assert.equal(calls.length, 0)
})

test('会话列表：app 不传 deviceId 时跨设备读全部', async () => {
  const { calls, db } = capture()
  const route = pick(createSessionRoutes({ db, logger, sse }), '/api/v1/sessions')

  await route.handler({ url: url('/api/v1/sessions?limit=5'), client: app })

  assert.doesNotMatch(calls[0].sql, /device_id =/)
  assert.deepEqual(calls[0].params, [6])
})

test('会话列表：app 指定 deviceId 时按该设备过滤', async () => {
  const { calls, db } = capture()
  const route = pick(createSessionRoutes({ db, logger, sse }), '/api/v1/sessions')

  await route.handler({ url: url('/api/v1/sessions?deviceId=localone&limit=5'), client: app })

  assert.match(calls[0].sql, /device_id = \$1/)
  assert.deepEqual(calls[0].params, ['localone', 6])
})

test('会话详情：device token 的查询带 device_id 条件', async () => {
  const { calls, db } = capture({ device_id: 'localone', session_id: 's1' })
  const route = pick(createSessionRoutes({ db, logger, sse }), '/api/v1/sessions/:sessionId')

  const result = await route.handler({
    params: { sessionId: 's1' },
    url: url('/api/v1/sessions/s1'),
    client: device
  })

  assert.match(calls[0].sql, /and device_id = \$2/)
  assert.deepEqual(calls[0].params, ['s1', 'localone'])
  assert.equal(result.session.sessionId, 's1')
})

test('消息流：device token 只能取自己的消息', async () => {
  const { calls, db } = capture()
  const route = pick(
    createSessionRoutes({ db, logger, sse }),
    '/api/v1/sessions/:sessionId/messages'
  )

  await route.handler({
    params: { sessionId: 's1' },
    url: url('/api/v1/sessions/s1/messages?limit=20'),
    client: device
  })

  assert.match(calls[0].sql, /session_id = \$1 and device_id = \$2/)
  assert.deepEqual(calls[0].params, ['s1', 'localone', 20])
})

test('命令列表：device token 只看自己的命令，app 看全部', async () => {
  const deviceCalls = capture()
  await pick(createCommandRoutes({ db: deviceCalls.db, logger, sse }), '/api/v1/commands').handler({
    url: url('/api/v1/commands?limit=10'),
    client: device
  })
  assert.match(deviceCalls.calls[0].sql, /device_id = \$1/)
  assert.deepEqual(deviceCalls.calls[0].params, ['localone', 10])

  const appCalls = capture()
  await pick(createCommandRoutes({ db: appCalls.db, logger, sse }), '/api/v1/commands').handler({
    url: url('/api/v1/commands?limit=10'),
    client: app
  })
  assert.doesNotMatch(appCalls.calls[0].sql, /device_id =/)
  assert.deepEqual(appCalls.calls[0].params, [10])
})

test('命令详情：device token 读别人的命令返回 403', async () => {
  const { db } = capture({ id: 'cmd_1', device_id: 'otherdevice', status: 'done' })
  const route = pick(createCommandRoutes({ db, logger, sse }), '/api/v1/commands/:id')

  await assert.rejects(
    route.handler({ params: { id: 'cmd_1' }, client: device }),
    (error) => error instanceof HttpError && error.status === 403 && error.code === 'forbidden'
  )
})

test('hook 列表：device token 只读自己的事件', async () => {
  const deviceCalls = capture()
  const deviceRoute = pick(createHookRoutes({ db: deviceCalls.db, logger, sse }), '/api/v1/hooks')
  await deviceRoute.handler({ url: url('/api/v1/hooks'), client: device })
  assert.match(deviceCalls.calls[0].sql, /device_id = \$1/)
  assert.deepEqual(deviceCalls.calls[0].params, ['localone', 50])

  const appCalls = capture()
  const appRoute = pick(createHookRoutes({ db: appCalls.db, logger, sse }), '/api/v1/hooks')
  await appRoute.handler({ url: url('/api/v1/hooks'), client: app })
  assert.doesNotMatch(appCalls.calls[0].sql, /device_id =/)
  assert.deepEqual(appCalls.calls[0].params, [50])
})

test('sseMayReceive：device 只看自己，app 全收，缺少 deviceId 时不发给 device', () => {
  assert.equal(sseMayReceive(device, { deviceId: 'localone', sessionId: 's1' }), true)
  assert.equal(sseMayReceive(device, { deviceId: 'other', sessionId: 's1' }), false)
  assert.equal(sseMayReceive(device, { sessionId: 's1' }), false)
  assert.equal(sseMayReceive(app, { deviceId: 'other' }), true)
  assert.equal(sseMayReceive(null, { deviceId: 'other' }), true)
})

test('SSE 广播按连接方设备过滤', () => {
  const deviceFrames = []
  const appFrames = []
  const channel = createSseChannel({ heartbeatMs: 60_000, logger })

  channel.attach({
    req: { on() {} },
    res: {
      writeHead() {},
      write(frame) {
        deviceFrames.push(frame)
      },
      end() {}
    },
    client: device
  })
  channel.attach({
    req: { on() {} },
    res: {
      writeHead() {},
      write(frame) {
        appFrames.push(frame)
      },
      end() {}
    },
    client: app
  })

  assert.equal(deviceFrames.length, 1) // 只有 ': connected'
  channel.broadcast('session', { deviceId: 'other', sessionId: 's1' })
  assert.equal(deviceFrames.length, 1)
  assert.equal(appFrames.length, 2)

  channel.broadcast('session', { deviceId: 'localone', sessionId: 's2' })
  assert.equal(deviceFrames.length, 2)
  assert.equal(appFrames.length, 3)
  assert.match(deviceFrames.at(-1), /event: session/)

  channel.closeAll()
})

test('HTTP 层：跨设备读返回 403，app 读全部返回 200', async () => {
  const db = {
    async many() {
      return []
    },
    async one() {
      return null
    }
  }
  const tokens = {
    'dev-token': { id: 'localone', role: 'device' },
    'app-token': { id: 'phone', role: 'app' }
  }
  const app = createApp({
    routes: createSessionRoutes({ db, logger, sse }),
    auth: { resolve: async (token) => tokens[token] ?? null },
    logger,
    corsOrigin: '*',
    maxBodyBytes: 1024,
    rateLimit: { perSec: 100, burst: 100 }
  })
  const server = createHttpServer(app)
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  const base = `http://127.0.0.1:${server.address().port}`

  try {
    const forbidden = await fetch(`${base}/api/v1/sessions?deviceId=other`, {
      headers: { authorization: 'Bearer dev-token' }
    })
    assert.equal(forbidden.status, 403)
    assert.equal((await forbidden.json()).code, 'device_mismatch')

    const ok = await fetch(`${base}/api/v1/sessions?limit=1`, {
      headers: { authorization: 'Bearer app-token' }
    })
    assert.equal(ok.status, 200)
    assert.equal((await ok.json()).ok, true)
  } finally {
    await new Promise((resolve) => server.close(resolve))
  }
})
