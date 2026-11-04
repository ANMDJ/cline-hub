import { HttpError, sseOriginAllowed } from '../http.js'
import { createAppRoutes } from './app.js'
import { createAttachmentRoutes } from './attachments.js'
import { createClientRoutes } from './clients.js'
import { createCommandRoutes } from './commands.js'
import { createDeepSeekRoutes } from './deepseek.js'
import { createHookRoutes } from './hooks.js'
import { createSessionRoutes } from './sessions.js'

export function createRoutes({ db, logger, sse, config, startedAt, tickets }) {
  const health = {
    method: 'GET',
    pattern: '/api/v1/health',
    auth: 'none',
    async handler() {
      let dbOk = false
      let latencyMs = null
      try {
        latencyMs = await db.ping()
        dbOk = true
      } catch (error) {
        logger.error('db health check failed', { message: error.message })
      }
      return {
        ok: dbOk,
        service: 'cline-hub',
        version: config.version,
        uptimeSec: Math.round((Date.now() - startedAt) / 1000),
        db: { ok: dbOk, latencyMs },
        sseClients: sse.size,
        time: new Date().toISOString()
      }
    }
  }

  const events = {
    method: 'GET',
    pattern: '/api/v1/events',
    auth: 'any',
    handler({ req, res, client }) {
      // 带了 Origin 就必须同源或在白名单里（P43 / ADR-65）。
      // App / bridge / curl 不带 Origin，照常放行。
      if (!sseOriginAllowed(req, config.sseAllowedOrigins ?? [])) {
        logger.warn('sse origin rejected', { origin: req.headers?.origin ?? '' })
        throw new HttpError(403, 'origin not allowed for SSE', 'origin_not_allowed')
      }
      sse.attach({ req, res, client })
      return undefined // response stays open
    }
  }

  // 换一张一次性 SSE 票据（P41 / ADR-64）：URL 里只出现 `clt_…`，不出现长期 token。
  const sseTicket = {
    method: 'POST',
    pattern: '/api/v1/sse-ticket',
    auth: 'any',
    handler({ client }) {
      if (!tickets) {
        throw new HttpError(503, 'sse tickets are not enabled', 'sse_ticket_disabled')
      }
      return { ok: true, ...tickets.issue(client) }
    }
  }

  return [
    health,
    sseTicket,
    events,
    ...createAppRoutes({ logger }),
    ...createClientRoutes({ db, logger }),
    ...createSessionRoutes({ db, logger, sse }),
    ...createHookRoutes({ db, logger, sse }),
    ...createAttachmentRoutes({ db, logger, config }),
    ...createCommandRoutes({ db, logger, sse, config }),
    ...createDeepSeekRoutes({ logger, config })
  ]
}
