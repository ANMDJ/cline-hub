import assert from 'node:assert/strict'
import test from 'node:test'

import { createApp, createSseChannel, sseOriginAllowed } from '../src/http.js'
import { createSseTickets } from '../src/ticket.js'

const logger = {
  info() {},
  warn() {},
  error() {},
  debug() {}
}

/** 只记着「有没有被 end」的假响应：够验连接上限与关闭逻辑。 */
function fakeRes() {
  const state = { written: [], ended: false, status: 0, headers: {}, body: '' }
  return {
    state,
    setHeader(key, value) {
      state.headers[String(key).toLowerCase()] = value
    },
    writeHead(status, headers) {
      state.status = status
      for (const [key, value] of Object.entries(headers ?? {})) {
        state.headers[String(key).toLowerCase()] = value
      }
      return this
    },
    write(chunk) {
      state.written.push(String(chunk))
      return true
    },
    end(chunk) {
      if (chunk !== undefined) state.body += String(chunk)
      state.ended = true
    },
    get writableEnded() {
      return state.ended
    }
  }
}

function fakeReq(url) {
  return {
    method: 'GET',
    url,
    headers: {},
    socket: { remoteAddress: '127.0.0.1' },
    on() {}
  }
}

function attach(channel, clientId) {
  const res = fakeRes()
  channel.attach({ req: fakeReq('/api/v1/events'), res, client: { id: clientId, role: 'app' } })
  return res
}

test('SSE 票据：一次性、60 秒、只存 hash', () => {
  const tickets = createSseTickets({ ttlMs: 60_000, logger })
  const issued = tickets.issue({ id: 'phone', name: 'Pixel', role: 'app' })

  assert.match(issued.ticket, /^clt_[0-9a-f]{48}$/)
  assert.equal(issued.expiresInSec, 60)
  assert.deepEqual(tickets.claim(issued.ticket), { id: 'phone', name: 'Pixel', role: 'app' })
  assert.equal(tickets.claim(issued.ticket), null, '重放必须失败（一次性）')
  assert.equal(tickets.size, 0, 'claim 之后不留条目')
  tickets.close()
})

test('SSE 票据：过期换不到身份，未知票据返回 null', () => {
  let clock = 1_000
  const tickets = createSseTickets({ ttlMs: 60_000, now: () => clock, logger })
  const issued = tickets.issue({ id: 'phone', role: 'app' })

  clock += 61_000
  assert.equal(tickets.claim(issued.ticket), null)
  assert.equal(tickets.claim('clt_does_not_exist'), null)
  assert.equal(tickets.claim(''), null)
  tickets.close()
})

test('createApp：?ticket= 换到身份，且票据只能换一次', async () => {
  const tickets = createSseTickets({ ttlMs: 60_000, logger })
  const handler = createApp({
    routes: [
      {
        method: 'GET',
        pattern: '/api/v1/events',
        auth: 'app',
        handler: ({ client }) => ({ ok: true, role: client.role })
      }
    ],
    auth: { resolve: async () => null },
    logger,
    corsOrigin: '*',
    maxBodyBytes: 1024,
    rateLimit: { perSec: 1e6, burst: 1e6 },
    sseTickets: tickets
  })

  const issued = tickets.issue({ id: 'phone', name: 'Pixel', role: 'app' })

  const first = fakeRes()
  await handler(fakeReq(`/api/v1/events?ticket=${issued.ticket}`), first)
  assert.equal(first.state.status, 200)
  assert.equal(JSON.parse(first.state.body).role, 'app')

  const replay = fakeRes()
  await handler(fakeReq(`/api/v1/events?ticket=${issued.ticket}`), replay)
  assert.equal(replay.state.status, 401, '同一张票据不能换第二次')

  // 票据只对 events 生效：别的路径带上它照样没身份
  const other = createApp({
    routes: [
      {
        method: 'GET',
        pattern: '/api/v1/sessions',
        auth: 'app',
        handler: () => ({ ok: true })
      }
    ],
    auth: { resolve: async () => null },
    logger,
    corsOrigin: '*',
    maxBodyBytes: 1024,
    rateLimit: { perSec: 1e6, burst: 1e6 },
    sseTickets: tickets
  })
  const anotherTicket = tickets.issue({ id: 'phone', role: 'app' })
  const wrongPath = fakeRes()
  await other(fakeReq(`/api/v1/sessions?ticket=${anotherTicket.ticket}`), wrongPath)
  assert.equal(wrongPath.state.status, 401)
  tickets.close()
})

test('Origin：无 Origin 放行、同源放行、跨源必须进白名单（P43）', () => {
  const sameOrigin = {
    origin: 'https://hub.littlewish.top:8443',
    host: 'hub.littlewish.top:8443'
  }
  const crossOrigin = { origin: 'https://evil.example', host: 'hub.littlewish.top:8443' }

  assert.equal(sseOriginAllowed({ headers: {} }, []), true, 'App / curl 不带 Origin')
  assert.equal(sseOriginAllowed({ headers: sameOrigin }, []), true)
  assert.equal(sseOriginAllowed({ headers: crossOrigin }, []), false)
  assert.equal(sseOriginAllowed({ headers: crossOrigin }, ['https://evil.example']), true)
  assert.equal(sseOriginAllowed({ headers: crossOrigin }, ['https://evil.example/']), true)
  assert.equal(sseOriginAllowed({ headers: crossOrigin }, ['*']), true)
  assert.equal(sseOriginAllowed({ headers: { origin: 'not a url', host: 'x' } }, []), false)
})

test('单 token 连接上限：超了踢最旧的一条，其他 token 不受影响（P43）', () => {
  const channel = createSseChannel({
    heartbeatMs: 1e9,
    maxPerClient: 3,
    idleTimeoutMs: 600_000,
    logger
  })

  const first = attach(channel, 'phone')
  attach(channel, 'phone')
  attach(channel, 'phone')
  assert.equal(channel.size, 3)

  const fourth = attach(channel, 'phone')
  assert.equal(channel.size, 3, '第 4 条进来后仍是最多 3 条')
  assert.equal(first.state.ended, true, '最旧的一条被 end 掉')
  assert.equal(fourth.state.ended, false)

  attach(channel, 'tablet')
  assert.equal(channel.size, 4, '另一个 token 有自己的额度')

  channel.closeAll()
})

test('空闲超时：心跳间隔内没有任何写入的连接会被断开（P43）', async () => {
  const channel = createSseChannel({
    heartbeatMs: 15,
    idleTimeoutMs: 5,
    maxPerClient: 8,
    logger
  })

  const res = attach(channel, 'phone')
  assert.equal(channel.size, 1)
  await new Promise((resolve) => setTimeout(resolve, 120))

  assert.equal(channel.size, 0)
  assert.equal(res.state.ended, true)
  channel.closeAll()
})
