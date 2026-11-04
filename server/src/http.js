import http from 'node:http'
import crypto from 'node:crypto'
import { clientIp, createRateLimiter, ipAllowed, isLoopback } from './net.js'

export class HttpError extends Error {
  constructor(status, message, code = 'error') {
    super(message)
    this.status = status
    this.code = code
  }
}

export function sendJson(res, status, body) {
  if (res.writableEnded) return
  const payload = JSON.stringify(body)
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(payload),
    'cache-control': 'no-store'
  })
  res.end(payload)
}

/** Reads the request body as JSON. Empty body -> {} so optional fields are fine. */
export function readJsonBody(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let size = 0
    let settled = false

    const fail = (error) => {
      if (settled) return
      settled = true
      reject(error)
    }

    req.on('data', (chunk) => {
      size += chunk.length
      if (size > limit) {
        fail(new HttpError(413, `body larger than ${limit} bytes`, 'body_too_large'))
        req.destroy()
        return
      }
      chunks.push(chunk)
    })

    req.on('end', () => {
      if (settled) return
      settled = true
      const raw = Buffer.concat(chunks).toString('utf8').trim()
      if (!raw) return resolve({})
      try {
        resolve(JSON.parse(raw))
      } catch {
        reject(new HttpError(400, 'body is not valid JSON', 'invalid_json'))
      }
    })

    req.on('error', (error) => fail(new HttpError(400, error.message, 'request_error')))
  })
}

function compilePattern(pattern) {
  const keys = []
  const source = pattern.replace(/\/:([a-zA-Z_][a-zA-Z0-9_]*)/g, (_, key) => {
    keys.push(key)
    return '/([^/]+)'
  })
  return { regex: new RegExp(`^${source}$`), keys }
}

function bearerToken(req, url) {
  const header = req.headers.authorization ?? ''
  if (header.toLowerCase().startsWith('bearer ')) return header.slice(7).trim()
  // EventSource / SSE clients cannot set headers, so tokens are also accepted here
  return url.searchParams.get('token') ?? ''
}

const ROLE_RULES = {
  none: () => true,
  any: (client) => Boolean(client),
  admin: (client) => client?.role === 'admin',
  device: (client) => client?.role === 'device' || client?.role === 'admin',
  app: (client) => client?.role === 'app' || client?.role === 'admin'
}

/**
 * Minimal router: no framework, no magic. A handler returns a plain object
 * (sent as 200 JSON) or `undefined` when it already wrote the response (SSE).
 */
export function createApp({
  routes,
  auth,
  logger,
  corsOrigin,
  maxBodyBytes,
  rateLimit,
  allowIps = [],
  sseTickets = null
}) {
  const compiled = routes.map((route) => ({ ...route, ...compilePattern(route.pattern) }))
  const takeToken = createRateLimiter(rateLimit ?? {})

  return async function handler(req, res) {
    const startedAt = Date.now()
    const requestId = crypto.randomBytes(4).toString('hex')
    const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`)

    res.setHeader('access-control-allow-origin', corsOrigin)
    res.setHeader('access-control-allow-headers', 'authorization, content-type')
    res.setHeader('access-control-allow-methods', 'GET, POST, PATCH, DELETE, OPTIONS')
    res.setHeader('x-request-id', requestId)

    if (req.method === 'OPTIONS') {
      res.writeHead(204).end()
      return
    }

    const ip = clientIp(req)

    // 白名单为空时对所有人开放；本机请求永远放行，保证 health/smoke 可用
    if (allowIps.length > 0 && !isLoopback(ip) && !ipAllowed(ip, allowIps)) {
      logger.warn('ip not allowed', { requestId, ip, path: url.pathname })
      sendJson(res, 403, { ok: false, code: 'ip_not_allowed', message: 'this address is not allowed' })
      return
    }

    if (!takeToken(ip)) {
      logger.warn('rate limited', { requestId, ip, path: url.pathname })
      res.setHeader('retry-after', '1')
      sendJson(res, 429, { ok: false, code: 'rate_limited', message: 'too many requests, slow down' })
      return
    }

    let client = null
    try {
      client = await auth.resolve(bearerToken(req, url))
      // SSE 短期票据（P41 / ADR-64）：URL 里只有一次性 ticket，长期 token
      // 不再进 access log。只对 events 生效，别把票据当成万能凭据。
      if (!client && sseTickets && url.pathname === '/api/v1/events') {
        const ticket = url.searchParams.get('ticket')
        if (ticket) client = sseTickets.claim(ticket)
      }
    } catch (error) {
      logger.error('auth lookup failed', { requestId, message: error.message })
      sendJson(res, 503, { ok: false, code: 'auth_unavailable', message: 'auth backend unavailable' })
      return
    }

    for (const route of compiled) {
      if (route.method !== req.method) continue
      const match = route.regex.exec(url.pathname)
      if (!match) continue

      const params = {}
      route.keys.forEach((key, index) => {
        params[key] = decodeURIComponent(match[index + 1])
      })

      if (!ROLE_RULES[route.auth](client)) {
        const status = client ? 403 : 401
        sendJson(res, status, {
          ok: false,
          code: client ? 'forbidden' : 'unauthorized',
          message: client ? `role ${client.role} cannot access this route` : 'missing or invalid token'
        })
        logger.warn('access denied', {
          requestId,
          path: url.pathname,
          status,
          role: client?.role ?? 'anonymous'
        })
        return
      }

      try {
        let body = {}
        if (req.method === 'POST' || req.method === 'PATCH' || req.method === 'PUT') {
          // 路由可以单独放宽 body 上限（目前只有附件上传会用到），
          // 默认仍是全局 maxBodyBytes。
          body = await readJsonBody(req, route.bodyLimit ?? maxBodyBytes)
        }

        const result = await route.handler({ req, res, url, params, body, client, requestId })
        if (result !== undefined) sendJson(res, route.status ?? 200, result)
        logger.info('request', {
          requestId,
          ip,
          method: req.method,
          path: url.pathname,
          status: res.statusCode,
          ms: Date.now() - startedAt,
          role: client?.role ?? 'anonymous'
        })
      } catch (error) {
        const status = error instanceof HttpError ? error.status : 500
        const code = error instanceof HttpError ? error.code : 'internal_error'
        if (status >= 500) {
          logger.error('request failed', {
            requestId,
            path: url.pathname,
            message: error.message,
            stack: error.stack
          })
        } else {
          logger.warn('request rejected', {
            requestId,
            path: url.pathname,
            status,
            message: error.message
          })
        }
        sendJson(res, status, { ok: false, code, message: error.message })
      }
      return
    }

    sendJson(res, 404, {
      ok: false,
      code: 'not_found',
      message: `${req.method} ${url.pathname} not found`
    })
  }
}

/**
 * SSE 不是「广播给所有人」：`device` token 只该收到自己的事件（ADR-43）。
 *
 * 事件负载里没有 `deviceId` 时对 device 一律不发 —— 宁可少推，也别串设备。
 * `app` / `admin` 保持全量（手机端要跨设备看）。
 */
export function sseMayReceive(client, data) {
  if (client?.role !== 'device') return true
  return Boolean(data && typeof data === 'object' && data.deviceId === client.id)
}

/**
 * SSE 的 Origin 白名单（P43 / ADR-65）。
 *
 * 非浏览器客户端（App / bridge / curl）不带 Origin，照常放行 —— 它们的凭据是
 * 自己带的 Bearer / ticket，不存在「浏览器自动带 cookie」那类风险。
 * 带了 Origin 就必须与请求自身同源（Web 预览 / 以后接浏览器端），
 * 或在 `HUB_SSE_ALLOWED_ORIGINS` 里（逗号分隔，`*` = 全放行）。
 */
export function sseOriginAllowed(req, allowed = []) {
  const origin = String(req.headers?.origin ?? '').trim()
  if (!origin) return true
  const normalized = origin.replace(/\/+$/, '')
  const list = (allowed ?? [])
    .map((item) => String(item ?? '').trim().replace(/\/+$/, ''))
    .filter(Boolean)
  if (list.includes('*') || list.includes(normalized)) return true
  const host = String(req.headers?.host ?? '').trim()
  if (!host) return false
  try {
    return new URL(normalized).host === host
  } catch {
    return false
  }
}

/**
 * Server-Sent Events channel. The phone can keep one of these open instead of
 * polling; the bridge keeps using the plain outbox, so SSE is optional.
 *
 * 纵深防御（P43 / ADR-65），都是「以后接浏览器端 / App 反复重连」的兜底：
 * - 单 token 最多 [maxPerClient] 条连接，超了踢最旧的一条（不报错，客户端自己重连）；
 * - [idleTimeoutMs] 内没有任何写入就断开（心跳会刷新时间戳，所以它只兜底
 *   「心跳定时器卡住 / 半开连接」这种情况，正常长连接不会被它误杀）。
 */
export function createSseChannel({
  heartbeatMs,
  idleTimeoutMs = 600_000,
  maxPerClient = 8,
  logger
}) {
  const clients = new Set()
  const maxPerKey =
    Number.isFinite(maxPerClient) && maxPerClient > 0 ? Math.floor(maxPerClient) : 8
  const idleMs =
    Number.isFinite(idleTimeoutMs) && idleTimeoutMs > 0 ? idleTimeoutMs : 600_000

  function drop(entry, reason) {
    if (!clients.delete(entry)) return
    try {
      entry.res.end()
    } catch {}
    logger?.debug?.('sse client dropped', {
      id: entry.id,
      key: entry.key,
      reason,
      total: clients.size
    })
  }

  const timer = setInterval(() => {
    const now = Date.now()
    for (const entry of clients) {
      if (now - entry.lastWriteAt > idleMs) {
        drop(entry, 'idle')
        continue
      }
      try {
        entry.res.write(': ping\n\n')
        entry.lastWriteAt = now
      } catch {
        drop(entry, 'write_failed')
      }
    }
  }, heartbeatMs)
  timer.unref?.()

  return {
    attach({ req, res, client }) {
      res.writeHead(200, {
        'content-type': 'text/event-stream; charset=utf-8',
        'cache-control': 'no-cache, no-transform',
        connection: 'keep-alive',
        'x-accel-buffering': 'no'
      })
      res.write(': connected\n\n')

      // 单 token 上限：先踢最旧的（App 在弱网下反复重连时不会把连接数堆上去）。
      const key = client?.id ?? 'anonymous'
      const same = [...clients].filter((entry) => entry.key === key)
      const overflow = same.length - maxPerKey + 1
      if (overflow > 0) {
        for (const old of same.slice(0, overflow)) drop(old, 'superseded')
      }

      const entry = {
        res,
        client,
        key,
        id: crypto.randomBytes(4).toString('hex'),
        lastWriteAt: Date.now()
      }
      clients.add(entry)
      req.on('close', () => clients.delete(entry))
      logger?.debug?.('sse client attached', {
        id: entry.id,
        role: client?.role,
        total: clients.size
      })
    },

    broadcast(event, data) {
      if (clients.size === 0) return 0
      const frame = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`
      let sent = 0
      for (const entry of clients) {
        if (!sseMayReceive(entry.client, data)) continue
        try {
          entry.res.write(frame)
          entry.lastWriteAt = Date.now()
          sent += 1
        } catch {
          drop(entry, 'write_failed')
        }
      }
      return sent
    },

    get size() {
      return clients.size
    },

    closeAll() {
      clearInterval(timer)
      for (const entry of clients) {
        try {
          entry.res.end()
        } catch {}
      }
      clients.clear()
    }
  }
}

export function createHttpServer(handler) {
  return http.createServer((req, res) => {
    handler(req, res).catch((error) => {
      if (!res.writableEnded) {
        sendJson(res, 500, { ok: false, code: 'internal_error', message: error.message })
      }
    })
  })
}
