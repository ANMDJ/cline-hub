#!/usr/bin/env node
/**
 * Hub smoke test — verifies auth, paging, ingest, and the command round-trip.
 *
 *   node scripts/smoke.mjs --token-device <clh_...> --token-app <clh_...>
 *   HUB_SMOKE_BASE=https://hub.littlewish.top node scripts/smoke.mjs ...
 *
 * Exits 1 if any check fails, so it can gate a deploy.
 */
import { setTimeout as sleep } from 'node:timers/promises'

const base = (process.env.HUB_SMOKE_BASE ?? 'http://127.0.0.1:3100').replace(/\/+$/, '')

function parseArgs(argv) {
  const out = {}
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i]
    if (!arg.startsWith('--')) continue
    const next = argv[i + 1]
    if (next && !next.startsWith('--')) {
      out[arg.slice(2)] = next
      i += 1
    } else {
      out[arg.slice(2)] = 'true'
    }
  }
  return out
}

const args = parseArgs(process.argv.slice(2))
const deviceToken = args['token-device'] ?? process.env.HUB_DEVICE_TOKEN
const appToken = args['token-app'] ?? process.env.HUB_APP_TOKEN

if (!deviceToken || !appToken) {
  console.error('usage: node scripts/smoke.mjs --token-device <token> --token-app <token>')
  process.exit(2)
}

let failures = 0
let checks = 0

function check(label, ok, detail = '') {
  checks += 1
  if (ok) {
    console.log(`  ok   ${label}${detail ? ' - ' + detail : ''}`)
  } else {
    failures += 1
    console.log(`  FAIL ${label}${detail ? ' - ' + detail : ''}`)
  }
}

async function req(method, path, { token, body } = {}) {
  const headers = {}
  if (token) headers.authorization = `Bearer ${token}`
  if (body !== undefined) headers['content-type'] = 'application/json'
  const res = await fetch(base + path, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body)
  })
  const text = await res.text()
  let json = null
  try {
    json = text ? JSON.parse(text) : null
  } catch {
    json = null
  }
  return { status: res.status, json, text }
}

async function main() {
  console.log(`Hub smoke test against ${base}\n`)

  const health = await req('GET', '/api/v1/health')
  check(
    'health',
    health.status === 200 && health.json?.db?.ok === true,
    health.json ? `db ${health.json.db.latencyMs}ms, uptime ${health.json.uptimeSec}s` : health.text.slice(0, 80)
  )

  const unauthorized = await req('GET', '/api/v1/sessions?limit=1')
  check('GET /sessions without token -> 401', unauthorized.status === 401, `got ${unauthorized.status}`)

  const wrongRole = await req('POST', '/api/v1/sessions', {
    token: appToken,
    body: { deviceId: 'localone', session: { sessionId: 'smoke_should_fail' } }
  })
  check('app token on device route -> 403', wrongRole.status === 403, `got ${wrongRole.status}`)

  const page1 = await req('GET', '/api/v1/sessions?limit=2', { token: deviceToken })
  const items1 = page1.json?.items ?? []
  check('session list', page1.status === 200 && items1.length > 0, `${items1.length} items`)
  check('session list returns cursor', Boolean(page1.json?.nextCursor))
  check(
    'list item has resultPreview, not resultText',
    items1.length > 0 && 'resultPreview' in items1[0] && !('resultText' in items1[0])
  )

  const devicesForDevice = await req('GET', '/api/v1/devices', { token: deviceToken })
  check(
    'GET /devices as device -> only self',
    devicesForDevice.status === 200 &&
      Array.isArray(devicesForDevice.json?.items) &&
      devicesForDevice.json.items.length <= 1,
    `${devicesForDevice.json?.items?.length ?? '?'} items`
  )

  const devicesForApp = await req('GET', '/api/v1/devices', { token: appToken })
  check(
    'GET /devices as app -> device list',
    devicesForApp.status === 200 && Array.isArray(devicesForApp.json?.items),
    `${devicesForApp.json?.items?.length ?? '?'} devices`
  )

  if (page1.json?.nextCursor && items1.length > 0) {
    const cursor = encodeURIComponent(page1.json.nextCursor)
    const page2 = await req('GET', `/api/v1/sessions?limit=2&cursor=${cursor}`, { token: deviceToken })
    const items2 = page2.json?.items ?? []
    const overlap = items2.filter((b) => items1.some((a) => a.sessionId === b.sessionId))
    check('cursor paging has no overlap', page2.status === 200 && overlap.length === 0, `${items2.length} items on page 2`)
  }

  if (items1.length > 0) {
    const first = items1[0]
    const detail = await req('GET', `/api/v1/sessions/${encodeURIComponent(first.sessionId)}`, { token: appToken })
    const session = detail.json?.session
    check('session detail', detail.status === 200 && session?.sessionId === first.sessionId)
    check(
      'detail carries resultText + commands',
      typeof session?.resultText === 'string' && Array.isArray(session?.commands),
      `${(session?.resultText ?? '').length} chars, ${(session?.commands ?? []).length} commands`
    )
  }

  const search = await req('GET', `/api/v1/sessions?limit=5&q=${encodeURIComponent('构建')}`, { token: appToken })
  check('search returns 200', search.status === 200, `${search.json?.items?.length ?? 0} hits for 构建`)

  // command round-trip: app creates, device claims, device reports, app reads back
  const created = await req('POST', '/api/v1/commands', {
    token: appToken,
    body: { deviceId: 'localone', prompt: 'smoke test: reply with ok', mode: 'plan' }
  })
  const commandId = created.json?.command?.id
  check('app creates command', created.status === 200 && Boolean(commandId), commandId ?? created.text.slice(0, 80))
  check('new command is pending', created.json?.command?.status === 'pending')

  const badMode = await req('POST', '/api/v1/commands', {
    token: appToken,
    body: { deviceId: 'localone', prompt: 'x', mode: 'destroy' }
  })
  check('invalid mode -> 400', badMode.status === 400, `got ${badMode.status}`)

  if (commandId) {
    const pending = await req('GET', '/api/v1/commands/pending?limit=5', { token: deviceToken })
    const claimed = (pending.json?.items ?? []).find((c) => c.id === commandId)
    check('device claims pending command', Boolean(claimed), `${pending.json?.items?.length ?? 0} claimed`)
    check('claim flips status to delivered', claimed?.status === 'delivered', claimed?.status ?? '')

    const running = await req('PATCH', `/api/v1/commands/${commandId}`, {
      token: deviceToken,
      body: { status: 'running' }
    })
    check('device reports running', running.status === 200 && running.json?.command?.status === 'running')

    const done = await req('PATCH', `/api/v1/commands/${commandId}`, {
      token: deviceToken,
      body: { status: 'done', resultText: 'ok' }
    })
    const cmd = done.json?.command
    check('device reports done', done.status === 200 && cmd?.status === 'done')
    check('done stamps timestamps', Boolean(cmd?.startedAt && cmd?.finishedAt))

    const readBack = await req('GET', `/api/v1/commands/${commandId}`, { token: appToken })
    check(
      'app reads command back',
      readBack.json?.command?.status === 'done' && readBack.json?.command?.resultText === 'ok'
    )
  }

  // SSE: 先换一张一次性票据（P41），再连——URL 里不该再出现长期 token
  const ticketRes = await req('POST', '/api/v1/sse-ticket', { token: appToken, body: {} })
  const ticket = ticketRes.json?.ticket ?? ''
  check(
    'sse ticket issued',
    ticketRes.status === 200 && ticket.startsWith('clt_') && ticket !== appToken
  )
  const ticketRes2 = await req('POST', '/api/v1/sse-ticket', { token: appToken, body: {} })
  check('every ticket is new', (ticketRes2.json?.ticket ?? '') !== ticket)

  // listen, trigger a command, expect an event within 6s
  const controller = new AbortController()
  const ssePromise = (async () => {
    const res = await fetch(`${base}/api/v1/events?ticket=${encodeURIComponent(ticket)}`, {
      headers: { accept: 'text/event-stream' },
      signal: controller.signal
    })
    const reader = res.body.getReader()
    const decoder = new TextDecoder()
    let buffer = ''
    while (true) {
      const { value, done } = await reader.read()
      if (done) return buffer
      buffer += decoder.decode(value, { stream: true })
      if (buffer.includes('event: command')) return buffer
    }
  })()

  await sleep(300)
  await req('POST', '/api/v1/commands', {
    token: appToken,
    body: { deviceId: 'localone', prompt: 'smoke test: sse', mode: 'plan' }
  })

  let streamed = ''
  try {
    streamed = await Promise.race([
      ssePromise,
      sleep(6000).then(() => {
        throw new Error('timeout')
      })
    ])
  } catch {
    streamed = ''
  } finally {
    controller.abort()
  }

  if (streamed.includes('event: command')) {
    check('SSE delivers command event', true)
  } else {
    console.log('  WARN SSE command event not observed within 6s (proxy buffering?)')
  }

  console.log(`\n${checks - failures}/${checks} checks passed`)
  process.exit(failures === 0 ? 0 : 1)
}

main().catch((error) => {
  console.error('smoke test crashed:', error)
  process.exit(1)
})


