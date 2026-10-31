import { createClientRoutes } from './clients.js'
import { createCommandRoutes } from './commands.js'
import { createHookRoutes } from './hooks.js'
import { createSessionRoutes } from './sessions.js'

export function createRoutes({ db, logger, sse, config, startedAt }) {
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
      sse.attach({ req, res, client })
      return undefined // response stays open
    }
  }

  return [
    health,
    events,
    ...createClientRoutes({ db, logger }),
    ...createSessionRoutes({ db, logger, sse }),
    ...createHookRoutes({ db, logger, sse }),
    ...createCommandRoutes({ db, logger, sse })
  ]
}
