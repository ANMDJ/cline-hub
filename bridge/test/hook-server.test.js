import test from 'node:test'
import assert from 'node:assert/strict'

import { startHookServer } from '../src/hook-server.js'

const silentLogger = { info() {}, warn() {}, error() {} }

async function withServer(run) {
  const stops = []
  const stopOptions = []
  const hooks = []
  const server = await startHookServer({
    host: '127.0.0.1',
    port: 0,
    onHook: (payload) => hooks.push(payload),
    onStop: (reason, options) => {
      stops.push(reason)
      stopOptions.push(options)
    },
    logger: silentLogger
  })
  const { port } = server.address()
  try {
    await run({ base: `http://127.0.0.1:${port}`, stops, stopOptions, hooks })
  } finally {
    await new Promise((resolve) => server.close(resolve))
  }
}

test('POST /admin/stop 返回 202 + reason，之后才触发 onStop', async () => {
  await withServer(async ({ base, stops }) => {
    const response = await fetch(`${base}/admin/stop`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ reason: '升级 bridge' })
    })
    assert.equal(response.status, 202)
    assert.deepEqual(await response.json(), {
      ok: true,
      stopping: true,
      reason: '升级 bridge'
    })
    // onStop 挂在响应 finish 之后：给事件循环一点时间。
    await new Promise((resolve) => setTimeout(resolve, 100))
    assert.deepEqual(stops, ['升级 bridge'])
  })
})

test('/admin/stop 带 keepChildren: true 时把选项交给 onStop，不带时不出现该字段', async () => {
  await withServer(async ({ base, stopOptions }) => {
    const kept = await fetch(`${base}/admin/stop`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ reason: '在命令里重启', keepChildren: true })
    })
    assert.equal(kept.status, 202)
    assert.equal((await kept.json()).keepChildren, true)

    const plain = await fetch(`${base}/admin/stop`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ reason: '普通重启' })
    })
    // 默认响应体保持原样，别让老调用方（`npm run stop` 的日志）多出一行。
    assert.equal('keepChildren' in (await plain.json()), false)

    await new Promise((resolve) => setTimeout(resolve, 100))
    assert.deepEqual(stopOptions, [{ keepChildren: true }, { keepChildren: false }])
  })
})

test('/admin/stop 没带 reason 时退回 manual stop，超长 reason 截断到 200 字', async () => {
  await withServer(async ({ base, stops }) => {
    const empty = await fetch(`${base}/admin/stop`, { method: 'POST' })
    assert.equal(empty.status, 202)
    assert.equal((await empty.json()).reason, 'manual stop')

    const long = await fetch(`${base}/admin/stop`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ reason: 'x'.repeat(500) })
    })
    assert.equal((await long.json()).reason.length, 200)

    await new Promise((resolve) => setTimeout(resolve, 100))
    assert.equal(stops.length, 2)
  })
})

test('GET /admin/stop 不存在（404），/health 仍然正常', async () => {
  await withServer(async ({ base, stops }) => {
    const wrongMethod = await fetch(`${base}/admin/stop`)
    assert.equal(wrongMethod.status, 404)

    const health = await fetch(`${base}/health`)
    assert.equal(health.status, 200)
    assert.equal((await health.json()).service, 'cline-bridge')

    await new Promise((resolve) => setTimeout(resolve, 100))
    assert.deepEqual(stops, [])
  })
})

test('POST /hook 仍然把 payload 交给 onHook', async () => {
  await withServer(async ({ base, hooks }) => {
    const response = await fetch(`${base}/hook`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ hookEventName: 'session_done' })
    })
    assert.equal(response.status, 202)
    await new Promise((resolve) => setTimeout(resolve, 50))
    assert.deepEqual(hooks, [{ hookEventName: 'session_done' }])
  })
})
