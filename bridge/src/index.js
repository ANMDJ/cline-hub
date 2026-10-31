import fs from 'node:fs'
import path from 'node:path'

import { loadConfig } from './config.js'
import { createLogger } from './logger.js'
import { openSessionsDb, listSessionsSince, getSessionById } from './db.js'
import { extractSession } from './extract.js'
import { startHookServer } from './hook-server.js'
import { Outbox } from './outbox.js'
import { createCommandWorker } from './command-worker.js'

const ONCE = process.argv.includes('--once')
const EVENT_KEYS = ['hookEventName', 'hook_event_name', 'event']
const MAX_SENT_MEMORY = 2000

const cfg = loadConfig()
const logger = createLogger(cfg.logFile)
const state = loadState()
const outbox = new Outbox({
  file: cfg.outboxFile,
  hubUrl: cfg.hubUrl,
  deviceId: cfg.deviceId,
  deviceToken: cfg.deviceToken,
  logger
})
const commandWorker = createCommandWorker({ cfg, logger })

let db = null
let server = null
let shuttingDown = false
let ticking = false

try {
  db = openSessionsDb(cfg.dataDir)
} catch (error) {
  logger.warn('sessions.db unavailable, session collection disabled', { message: error.message })
}

function loadState() {
  const base = { lastUpdatedAt: '1970-01-01T00:00:00.000Z', sentSessions: [], pendingRunning: [] }
  try {
    if (!fs.existsSync(cfg.stateFile)) return base
    const parsed = JSON.parse(fs.readFileSync(cfg.stateFile, 'utf8'))
    return { ...base, ...parsed }
  } catch (error) {
    logger.warn('state load failed, starting fresh', { message: error.message })
    return base
  }
}

function saveState() {
  try {
    fs.writeFileSync(cfg.stateFile, JSON.stringify(state, null, 2), 'utf8')
  } catch (error) {
    logger.error('state save failed', { message: error.message })
  }
}

function workspaceName(root) {
  if (!root) return ''
  const trimmed = String(root).replace(/[\\/]+$/, '')
  return path.basename(trimmed) || trimmed
}

function allowedWorkspace(row) {
  const whitelist = cfg.workspaceWhitelist
  if (!Array.isArray(whitelist) || whitelist.length === 0) return true
  const root = String(row.workspace_root ?? '').toLowerCase()
  return whitelist.some((item) => root.includes(String(item).toLowerCase()))
}

function toRecord(row, extraction) {
  return {
    sessionId: row.session_id,
    source: row.source,
    status: row.status,
    exitCode: row.exit_code,
    provider: row.provider,
    model: row.model,
    cwd: row.cwd,
    workspaceRoot: row.workspace_root,
    workspace: workspaceName(row.workspace_root),
    prompt: row.prompt ?? '',
    startedAt: row.started_at,
    endedAt: row.ended_at,
    updatedAt: row.updated_at,
    resultOk: extraction.ok,
    resultError: extraction.ok ? '' : (extraction.reason ?? ''),
    resultText: extraction.resultText,
    resultTruncated: extraction.resultTruncated,
    userPrompt: extraction.userPrompt,
    commands: extraction.commands,
    metrics: extraction.metrics,
    collectedAt: new Date().toISOString()
  }
}

function emitSession(row) {
  if (state.sentSessions.includes(row.session_id)) return

  const extraction = extractSession(row.messages_path, cfg)
  const record = toRecord(row, extraction)
  outbox.add({ kind: 'session', body: { session: record } })

  state.sentSessions.push(row.session_id)
  if (state.sentSessions.length > MAX_SENT_MEMORY) {
    state.sentSessions.splice(0, state.sentSessions.length - MAX_SENT_MEMORY)
  }

  logger.info('session queued', {
    id: row.session_id,
    status: row.status,
    workspace: record.workspace,
    resultChars: record.resultText.length,
    commands: record.metrics.commandCount
  })
}

function pollSessions() {
  if (!db) return

  const rows = listSessionsSince(db, state.lastUpdatedAt, cfg.batchSize)
  for (const row of rows) {
    state.lastUpdatedAt = row.updated_at
    if (!allowedWorkspace(row)) continue
    if (row.status === 'running') {
      if (!state.pendingRunning.includes(row.session_id)) state.pendingRunning.push(row.session_id)
      continue
    }
    emitSession(row)
  }

  if (state.pendingRunning.length > 0) {
    const stillRunning = []
    for (const sessionId of state.pendingRunning) {
      const row = getSessionById(db, sessionId)
      if (!row) continue
      if (row.status === 'running') {
        stillRunning.push(sessionId)
        continue
      }
      emitSession(row)
    }
    state.pendingRunning = stillRunning
  }

  saveState()
}

function onHook(payload) {
  let event = ''
  for (const key of EVENT_KEYS) {
    if (typeof payload?.[key] === 'string' && payload[key]) {
      event = payload[key]
      break
    }
  }
  if (!event) {
    const root = payload?.workspaceRoots?.[0] ?? payload?.workspace?.rootPath ?? payload?.cwd ?? ''
    event = `agent_event:${workspaceName(root) || 'unknown'}`
  }

  outbox.add({ kind: 'hook', body: { event, payload, receivedAt: new Date().toISOString() } })
  logger.info('hook queued', { event, pending: outbox.pending })
}

async function tick() {
  if (ticking) return
  ticking = true
  try {
    pollSessions()
  } catch (error) {
    logger.error('session poll failed', { message: error.message })
  }
  try {
    await outbox.flush()
  } catch (error) {
    logger.error('outbox flush failed', { message: error.message })
  } finally {
    ticking = false
  }
  if (outbox.pending > 0) logger.info('outbox pending', { count: outbox.pending })

  if (!ONCE) {
    // 远程命令：后台执行，不阻塞采集/上报主循环
    commandWorker.tick().catch((error) => logger.error('command worker failed', { message: error.message }))
  }
}

async function shutdown(reason) {
  if (shuttingDown) return
  shuttingDown = true
  logger.info('shutting down', { reason, pending: outbox.pending })
  try {
    commandWorker.stop()
  } catch {}
  try {
    server?.close()
  } catch {}
  saveState()
  try {
    db?.close()
  } catch {}
  await logger.close()
  process.exit(0)
}

server = await startHookServer({ host: cfg.hookHost, port: cfg.hookPort, onHook, logger })

logger.info('bridge started', {
  config: cfg.configPath,
  deviceId: cfg.deviceId,
  hubUrl: cfg.hubUrl || '(empty: queueing locally)',
  dataDir: cfg.dataDir,
  pollIntervalMs: cfg.pollIntervalMs,
  pending: outbox.pending,
  commandsEnabled: commandWorker.enabled
})

if (!cfg.hubUrl) {
  logger.warn('hubUrl is empty: records stay in outbox.json until you set it in bridge/config.json')
}

await tick()

if (ONCE) {
  await shutdown('once')
} else {
  setInterval(tick, cfg.pollIntervalMs)
  process.on('SIGINT', () => shutdown('SIGINT'))
  process.on('SIGTERM', () => shutdown('SIGTERM'))
}
