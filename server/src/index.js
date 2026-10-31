import { config } from './env.js'
import { createLogger } from './logger.js'
import { createDb } from './db.js'
import { runMigrations } from './migrate.js'
import { createAuth } from './auth.js'
import { createApp, createHttpServer, createSseChannel } from './http.js'
import { createRoutes } from './routes/index.js'

const startedAt = Date.now()
const logger = createLogger({ file: config.logFile, level: config.logLevel })

let db = null
let sse = null
let server = null
let shuttingDown = false

function describeDatabase(url) {
  try {
    const parsed = new URL(url)
    return `${parsed.hostname}:${parsed.port || 5432}${parsed.pathname}`
  } catch {
    return '(invalid url)'
  }
}

async function shutdown(reason) {
  if (shuttingDown) return
  shuttingDown = true
  logger.info('shutting down', { reason })
  try {
    sse?.closeAll()
  } catch {}
  try {
    await new Promise((resolve) => server?.close(resolve) ?? resolve())
  } catch {}
  try {
    await db?.close()
  } catch {}
  await logger.close()
  process.exit(0)
}

async function main() {
  if (!config.databaseUrl) {
    logger.error('HUB_DATABASE_URL is empty: copy server/.env.example to server/.env and fill it in')
    process.exit(1)
  }
  if (!config.adminToken || config.adminToken.length < 16) {
    logger.warn('HUB_ADMIN_TOKEN is missing or short: creating clients will be rejected')
  }

  db = createDb({ databaseUrl: config.databaseUrl, logger })
  await db.ping()

  if (config.autoMigrate) {
    await runMigrations(db, logger)
  } else {
    logger.info('auto migrate disabled (HUB_AUTO_MIGRATE=0)')
  }

  const auth = createAuth({ db, adminToken: config.adminToken, logger })
  sse = createSseChannel({ heartbeatMs: config.sseHeartbeatMs, logger })
  const routes = createRoutes({ db, logger, sse, config, startedAt })
  const app = createApp({
    routes,
    auth,
    logger,
    corsOrigin: config.corsOrigin,
    maxBodyBytes: config.maxBodyBytes
  })

  server = createHttpServer(app)
  await new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(config.port, config.host, resolve)
  })

  logger.info('hub listening', {
    url: `http://${config.host}:${config.port}`,
    db: describeDatabase(config.databaseUrl),
    routes: routes.length,
    autoMigrate: config.autoMigrate,
    version: config.version
  })
}

process.on('SIGINT', () => void shutdown('SIGINT'))
process.on('SIGTERM', () => void shutdown('SIGTERM'))
process.on('unhandledRejection', (reason) => {
  logger.error('unhandled rejection', { message: reason instanceof Error ? reason.message : String(reason) })
})
process.on('uncaughtException', (error) => {
  logger.error('uncaught exception', { message: error.message, stack: error.stack })
  void shutdown('uncaughtException')
})

main().catch(async (error) => {
  logger.error('startup failed', { message: error.message, code: error.code })
  try {
    await db?.close()
  } catch {}
  await logger.close()
  process.exit(1)
})
