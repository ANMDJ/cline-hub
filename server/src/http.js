import http from 'node:http'
import crypto from 'node:crypto'

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
export function createApp({ routes, auth, logger, corsOrigin, maxBodyBytes }) {
  const compiled = routes.map((route) => ({ ...route, ...compilePattern(route.pattern) }))

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

    let client = null
    try {
      client = await auth.resolve(bearerToken(req, url))
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
          body = await readJsonBody(req, maxBodyBytes)
        }

        const result = await route.handler({ req, res, url, params, body, client, requestId })
        if (result !== undefined) sendJson(res, route.status ?? 200, result)
        logger.info('request', {
          requestId,
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
 * Server-Sent Events channel. The phone can keep one of these open instead of
 * polling; the bridge keeps using the plain outbox, so SSE is optional.
 */
export function createSseChannel({ heartbeatMs, logger }) {
  const clients = new Set()

  const timer = setInterval(() => {
    for (const entry of clients) {
      try {
        entry.res.write(': ping\n\n')
      } catch {
        clients.delete(entry)
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
      const entry = { res, client, id: crypto.randomBytes(4).toString('hex') }
      clients.add(entry)
      req.on('close', () => clients.delete(entry))
      logger.debug('sse client attached', { id: entry.id, role: client.role, total: clients.size })
    },

    broadcast(event, data) {
      if (clients.size === 0) return 0
      const frame = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`
      let sent = 0
      for (const entry of clients) {
        try {
          entry.res.write(frame)
          sent += 1
        } catch {
          clients.delete(entry)
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
