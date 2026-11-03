import assert from 'node:assert/strict'
import test from 'node:test'

import { HttpError } from '../src/http.js'
import { createDeepSeekRoutes } from '../src/routes/deepseek.js'

const logger = { info() {}, warn() {}, error() {}, debug() {} }

const BASE_CONFIG = {
  deepseekApiKey: 'sk-test-key',
  deepseekBaseUrl: 'https://api.deepseek.com',
  deepseekBalanceTtlSec: 60,
  deepseekTimeoutMs: 5000
}

function makeRoute({ config = BASE_CONFIG, fetchImpl } = {}) {
  const routes = createDeepSeekRoutes({ logger, config, fetchImpl })
  const route = routes.find((item) => item.pattern === '/api/v1/deepseek/balance')
  assert.ok(route, 'GET /api/v1/deepseek/balance not found')
  return route
}

/** 上游返回：状态码 + 原始文本。 */
function upstream(body, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    async text() {
      return typeof body === 'string' ? body : JSON.stringify(body)
    }
  }
}

const SAMPLE = {
  is_available: true,
  balance_infos: [
    {
      currency: 'CNY',
      total_balance: '110.00',
      granted_balance: '10.00',
      topped_up_balance: '100.00'
    }
  ]
}

const call = (refresh = false) => ({
  url: new URL(
    `http://127.0.0.1:3100/api/v1/deepseek/balance${refresh ? '?refresh=1' : ''}`
  )
})

test('余额：没配 DEEPSEEK_API_KEY 时返回 configured:false，且不请求上游', async () => {
  let calls = 0
  const route = makeRoute({
    config: { ...BASE_CONFIG, deepseekApiKey: '' },
    fetchImpl: async () => {
      calls += 1
      return upstream(SAMPLE)
    }
  })

  const result = await route.handler(call())

  assert.equal(calls, 0)
  assert.equal(result.ok, true)
  assert.equal(result.configured, false)
  assert.deepEqual(result.balances, [])
  assert.match(result.hint, /DEEPSEEK_API_KEY/)
})

test('余额：正常解析上游字段，并把 Key 放在 Authorization 头里', async () => {
  const seen = []
  const route = makeRoute({
    fetchImpl: async (url, options) => {
      seen.push({ url, options })
      return upstream(SAMPLE)
    }
  })

  const result = await route.handler(call())

  assert.equal(seen.length, 1)
  assert.equal(seen[0].url, 'https://api.deepseek.com/user/balance')
  assert.equal(seen[0].options.method, 'GET')
  assert.equal(seen[0].options.headers.authorization, 'Bearer sk-test-key')
  assert.equal(result.ok, true)
  assert.equal(result.configured, true)
  assert.equal(result.isAvailable, true)
  assert.equal(result.cached, false)
  assert.deepEqual(result.balances, [
    {
      currency: 'CNY',
      totalBalance: '110.00',
      grantedBalance: '10.00',
      toppedUpBalance: '100.00'
    }
  ])
  // 返回体里不能出现 Key（App 与日志都不该看到）
  assert.equal(JSON.stringify(result).includes('sk-test-key'), false)
})

test('余额：TTL 内重复请求走缓存，refresh=1 才再打上游', async () => {
  let calls = 0
  const route = makeRoute({
    fetchImpl: async () => {
      calls += 1
      return upstream(SAMPLE)
    }
  })

  await route.handler(call())
  const second = await route.handler(call())
  assert.equal(calls, 1)
  assert.equal(second.cached, true)

  const forced = await route.handler(call(true))
  assert.equal(calls, 2)
  assert.equal(forced.cached, false)
})

test('余额：并发请求共用同一个上游请求（不放大）', async () => {
  let calls = 0
  const route = makeRoute({
    fetchImpl: async () => {
      calls += 1
      await new Promise((resolve) => setTimeout(resolve, 10))
      return upstream(SAMPLE)
    }
  })

  const [a, b] = await Promise.all([route.handler(call()), route.handler(call())])
  assert.equal(calls, 1)
  assert.equal(a.balances.length, 1)
  assert.equal(b.balances.length, 1)
})

test('余额：上游 401 转成 deepseek_auth_failed（不能把 401 透传给 App）', async () => {
  const route = makeRoute({ fetchImpl: async () => upstream({ error: 'bad key' }, 401) })

  await assert.rejects(route.handler(call()), (error) => {
    assert.ok(error instanceof HttpError)
    assert.equal(error.status, 502)
    assert.equal(error.code, 'deepseek_auth_failed')
    return true
  })
})

test('余额：429 转成 deepseek_rate_limited', async () => {
  const route = makeRoute({ fetchImpl: async () => upstream({ error: 'slow down' }, 429) })

  await assert.rejects(
    route.handler(call()),
    (error) => error instanceof HttpError && error.code === 'deepseek_rate_limited'
  )
})

test('余额：网络不通给 deepseek_unreachable', async () => {
  const route = makeRoute({
    fetchImpl: async () => {
      throw new Error('getaddrinfo ENOTFOUND api.deepseek.com')
    }
  })

  await assert.rejects(route.handler(call()), (error) => {
    assert.ok(error instanceof HttpError)
    assert.equal(error.status, 503)
    assert.equal(error.code, 'deepseek_unreachable')
    return true
  })
})

test('余额：刷新失败时退回上一次结果并标 stale', async () => {
  let fail = false
  const route = makeRoute({
    fetchImpl: async () => {
      if (fail) throw new Error('socket hang up')
      return upstream(SAMPLE)
    }
  })

  const first = await route.handler(call())
  assert.equal(first.stale, undefined)

  fail = true
  const stale = await route.handler(call(true))
  assert.equal(stale.ok, true)
  assert.equal(stale.stale, true)
  assert.equal(stale.cached, true)
  assert.equal(stale.balances[0].totalBalance, '110.00')
  assert.match(stale.warning, /socket hang up/)
})

test('余额：上游返回非 JSON / 字段缺失时不崩，balances 为空数组', async () => {
  const bad = makeRoute({ fetchImpl: async () => upstream('<html>502 Bad Gateway</html>', 200) })
  await assert.rejects(
    bad.handler(call()),
    (error) => error instanceof HttpError && error.code === 'deepseek_bad_response'
  )

  const empty = makeRoute({
    fetchImpl: async () => upstream({ is_available: false, balance_infos: 'nope' })
  })
  const result = await empty.handler(call())
  assert.equal(result.isAvailable, false)
  assert.deepEqual(result.balances, [])
})
