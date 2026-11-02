import fs from 'node:fs'
import path from 'node:path'

import { loadConfig } from './config.js'
import { createLogger } from './logger.js'
import { openSessionsDb, listSessionsSince, getSessionById, listRecentSessions } from './db.js'
import { extractSession, extractTranscript, TRANSCRIPT_VERSION } from './extract.js'
import { projectInfo } from './project.js'
import { startHookServer } from './hook-server.js'
import { Outbox } from './outbox.js'
import { createCommandWorker } from './command-worker.js'

const ONCE = process.argv.includes('--once')
const EVENT_KEYS = ['hookEventName', 'hook_event_name', 'event']
const MAX_SENT_MEMORY = 2000

/**
 * 进行中会话的最小上报间隔。Cline 每产生一条消息都会刷新 sessions.updated_at，
 * 不加节流会把 outbox 和 Hub 的 upsert 打成每 5 秒一次。
 *
 * 消息级别的实时性靠 transcript 增量（见 emitTranscript）保证，这里只管会话快照。
 */
const RUNNING_MIN_INTERVAL_MS = Number(process.env.CLINE_HUB_RUNNING_MS) || 5000
/** 僵尸会话（DB 说 running、进程已死）没必要每轮都发，10 分钟一次足够。 */
const ZOMBIE_MIN_INTERVAL_MS = 10 * 60 * 1000

/**
 * 重发窗口：messages.json 是追加写的，最后一条 assistant 消息在流式输出时
 * 长度会一直变，所以每次回退几条重发，服务端按 message_id upsert 覆盖。
 */
const TRANSCRIPT_OVERLAP = 6

/** 一次性 transcript 回填的会话数（按 updated_at 倒序）。 */
const TRANSCRIPT_BACKFILL_LIMIT = 60

/** 每轮 tick 回填几个会话，避免一次把 outbox 塞满。 */
const TRANSCRIPT_BACKFILL_PER_TICK = 2

/** 回填一次性最多看多少条会话；按 updated_at 倒序，够覆盖"最近这两天"。 */
const BACKFILL_LIMIT = 100

/** session_id -> 上次上报 running 快照的本地时间，仅内存，重启后最多多推一次。 */
const runningEmitAt = new Map()
const zombieEmitAt = new Map()

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

/**
 * 旧版本把已上报会话存成 id 数组；升级成 { sessionId: 指纹 } 才能识别
 * "同一个会话后续又变了，需要重发"。迁移时旧 id 给空指纹，并打上
 * needsBackfill：水位线以下的旧会话靠一次性回填补推，之后正常去重。
 */
function normalizeSentSessions(raw) {
  const map = {}
  let migrated = false
  if (Array.isArray(raw)) {
    migrated = raw.length > 0
    for (const id of raw) {
      if (typeof id === 'string' && id) map[id] = ''
    }
    return { map, migrated }
  }
  if (raw && typeof raw === 'object') {
    for (const [id, fingerprint] of Object.entries(raw)) {
      if (typeof id === 'string' && id) {
        map[id] = typeof fingerprint === 'string' ? fingerprint : ''
      }
    }
  }
  return { map, migrated }
}

function loadState() {
  const base = {
    lastUpdatedAt: '1970-01-01T00:00:00.000Z',
    sentSessions: {},
    pendingRunning: [],
    needsBackfill: false,
    /** sessionId -> `${status}|${endedAt}`：完成通知的幂等键，防同一条反复弹 */
    completionEvents: {},
    /** sessionId -> { stamp, since, previous }：等待「稳定 30 秒」的终态 */
    pendingCompletions: {},
    /** sessionId -> { v: 抽取规则版本, n: 已上报条数, tail: 末条文本长度 } */
    transcripts: {},
    /** 尚未回填的历史会话队列，重启后接着跑 */
    transcriptBackfill: [],
    transcriptBackfillDone: false
  }
  try {
    if (!fs.existsSync(cfg.stateFile)) return base
    const parsed = JSON.parse(fs.readFileSync(cfg.stateFile, 'utf8'))
    const merged = { ...base, ...parsed }
    const { map, migrated } = normalizeSentSessions(merged.sentSessions)
    merged.sentSessions = map
    if (!Array.isArray(merged.pendingRunning)) merged.pendingRunning = []
    if (!merged.completionEvents || typeof merged.completionEvents !== 'object') merged.completionEvents = {}
    if (!merged.pendingCompletions || typeof merged.pendingCompletions !== 'object') merged.pendingCompletions = {}
    if (!merged.transcripts || typeof merged.transcripts !== 'object') merged.transcripts = {}
    if (!Array.isArray(merged.transcriptBackfill)) merged.transcriptBackfill = []
    // 迁移过，或者上一次迁移跑到一半（指纹为空串）都要回填一次；
    // 回填完成后 needsBackfill 会被写成 false 持久化，不会每次启动都重跑。
    const hasLegacyFingerprint = Object.values(map).some((fp) => fp === '')
    if (parsed.needsBackfill === true || (parsed.needsBackfill === undefined && (migrated || hasLegacyFingerprint))) {
      merged.needsBackfill = true
    }
    return merged
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

/**
 * Windows 上同一个目录可能被写成 `C:\a\b` 或 `C:/a/b`：cline CLI 写库时用正斜杠，
 * 白名单是人手填的反斜杠。比较前统一分隔符，否则 CLI 产生的会话会被白名单误杀
 * （实测 1793531135718_fl56b：workspace_root=C:/.../cline-hub 匹配不上 C:\...\cline-hub）。
 */
function normalizePath(value) {
  return String(value ?? '').replace(/\\/g, '/').toLowerCase()
}

function allowedWorkspace(row) {
  const whitelist = cfg.workspaceWhitelist
  if (!Array.isArray(whitelist) || whitelist.length === 0) return true
  const root = normalizePath(row.workspace_root)
  return whitelist.some((item) => root.includes(normalizePath(item)))
}

/**
 * 真实状态：DB 里的 `status` 有两类不可信，都得在这里纠正。
 *
 * 1. cline 偶尔把**仍在跑**的会话短暂写成 `failed`（hook 派发失败时落一次），
 *    过一会儿又翻回 `running`；没有 `ended_at` 的那种，按「还在跑」算。
 * 2. 反过来，`status=running` 但进程早没了（比如昨天 VS Code 里的会话，pid 已回收），
 *    那是僵尸：一直显示「执行中」是假的，按 `failed` 处理，并且只通知一次。
 */
function isProcessAlive(pid) {
  if (!pid) return false
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    // EPERM = 进程存在但没权限，仍然算活着
    return error?.code === 'EPERM'
  }
}

function sessionState(row) {
  const status = String(row.status ?? '')
  const pidDead = Boolean(row.pid) && !isProcessAlive(row.pid)
  if (status === 'running') {
    if (pidDead) return { status: 'failed', zombie: true }
    return { status, zombie: false }
  }
  if (status === 'failed') {
    if (!row.ended_at) return { status: 'running', zombie: false }
    // 失败但进程已经没了：可能是真失败，也可能是僵尸会话在 failed/running 之间来回翻，
    // 统一打上 zombie 标记，交给节流和幂等去压。
    return { status: 'failed', zombie: pidDead }
  }
  return { status, zombie: false }
}

function effectiveStatus(row) {
  return sessionState(row).status
}

function toRecord(row, extraction) {
  const project = projectInfo(row.workspace_root)
  return {
    sessionId: row.session_id,
    source: row.source,
    status: effectiveStatus(row),
    exitCode: row.exit_code,
    provider: row.provider,
    model: row.model,
    cwd: row.cwd,
    workspaceRoot: row.workspace_root,
    workspace: workspaceName(row.workspace_root),
    // 项目根：从工作目录向上找 .git / 构建标记，找不到就归为散会话（loose）
    project: project.project,
    projectRoot: project.projectRoot,
    projectKind: project.projectKind,
    prompt: row.prompt ?? '',
    startedAt: row.started_at,
    endedAt: row.ended_at,
    updatedAt: row.updated_at,
    resultOk: extraction.ok,
    resultError: extraction.ok ? '' : (extraction.reason ?? ''),
    resultText: extraction.resultText,
    resultTruncated: extraction.resultTruncated,
    // 优先 messages.json 里最后一条"真人"输入；全是系统注入时退回 sessions.prompt。
    userPrompt: extraction.userPrompt || String(row.prompt ?? '').trim().slice(0, 2000),
    commands: extraction.commands,
    metrics: extraction.metrics,
    collectedAt: new Date().toISOString()
  }
}

function fingerprintOf(row) {
  return `${row.status ?? ''}|${row.updated_at ?? ''}`
}

/** 记住某会话"已上报到哪个快照"，同时把内存上限维持在 MAX_SENT_MEMORY。 */
function rememberSent(sessionId, fingerprint) {
  const sent = state.sentSessions
  delete sent[sessionId]
  sent[sessionId] = fingerprint
  const ids = Object.keys(sent)
  const overflow = ids.length - MAX_SENT_MEMORY
  if (overflow > 0) {
    for (const id of ids.slice(0, overflow)) delete sent[id]
  }
}

/** 某会话的 transcript 水位：已上报到第几条、最后一条多长。 */
function transcriptCursor(sessionId) {
  const entry = state.transcripts[sessionId]
  if (!entry || entry.v !== TRANSCRIPT_VERSION) return { n: 0, tail: -1 }
  return { n: Number(entry.n) || 0, tail: Number(entry.tail ?? -1) }
}

function tailLength(messages) {
  const last = messages.at(-1)
  return last ? String(last.text ?? '').length : -1
}

/**
 * 把 messages.json 里新增的消息推给 Hub。
 *
 * 只发增量：从「已上报条数 - TRANSCRIPT_OVERLAP」切，服务端按
 * (device, session, message_id) upsert，重复发送只会覆盖成最新内容。
 * 条数和末条长度都没变就直接返回 —— running 会话每 3 秒扫一次也不会产生请求。
 */
function syncTranscript(row) {
  if (!row?.messages_path) return false

  const cursor = transcriptCursor(row.session_id)
  const result = extractTranscript(row.messages_path, cfg)
  if (!result.ok) return false

  const total = result.total
  const tail = tailLength(result.messages)
  if (cursor.n === total && cursor.tail === tail) return false

  // 文件被重写或变短（Cline 清理过会话）时水位线自然归零，重发一遍即可。
  const start = Math.max(0, Math.min(cursor.n, total) - TRANSCRIPT_OVERLAP)
  const pending = result.messages.slice(start)
  if (pending.length === 0) return false

  // 条数 + 字节双上限：单条消息现在可到 20000 字，40 条一封会撞 Hub 的 4MB body 上限。
  const batchSize = Number(cfg.messageBatch) > 0 ? Number(cfg.messageBatch) : 40
  const batchBytes = 64 * 1024
  let chunk = []
  let chunkBytes = 0
  let batches = 0
  const flush = () => {
    if (chunk.length === 0) return
    outbox.add({
      kind: 'messages',
      body: { sessionId: row.session_id, messages: chunk }
    })
    chunk = []
    chunkBytes = 0
    batches += 1
  }
  for (const message of pending) {
    const size = Buffer.byteLength(JSON.stringify(message))
    if (chunk.length > 0 && (chunk.length >= batchSize || chunkBytes + size > batchBytes)) flush()
    chunk.push(message)
    chunkBytes += size
  }
  flush()

  state.transcripts[row.session_id] = { v: TRANSCRIPT_VERSION, n: total, tail }
  logger.info('transcript queued', {
    id: row.session_id,
    from: start,
    total,
    batches
  })
  return true
}

/**
 * 会话从 running 走进终态时，补一条完成通知。
 *
 * 这条链路不依赖 Cline 的 hook 是否还会被调用（4.1.26 起全局 hooks 目录改成
 * 工作区级 `.clinerules/hooks`，老脚本就没再触发过），完全靠 bridge 自己看
 * sessions.db 的状态跃迁，所以换项目、换机器都成立。
 *
 * `sawRunning` 那道判断是必要的：首次回填会把几十个历史会话一次性翻出来，
 * 没有它手机的开机瞬间会被历史通知刷屏。
 */
/**
 * 终态必须「稳定」了才算数。
 *
 * 实测（2026-11-01）：kids_points_app 那个 VS Code 会话会周期性被写成 `failed`
 * 再翻回 `running`，每次还带一个新的 `ended_at` —— 按指纹去重根本拦不住，
 * 手机上「动态」会被同一条「执行失败」刷屏（20 分钟里 91 条）。
 *
 * 所以分两步：先排队，`COMPLETION_SETTLE_MS` 后复查，仍是同一个终态才真正发；
 * 中途翻回 running 或换了个终态，就直接丢弃。
 */
const COMPLETION_SETTLE_MS = 30_000

function completionStamp(row) {
  const state = sessionState(row)
  // 僵尸会话的 ended_at 会随抖动变化，用它做键会重复通知，固定成 `failed|zombie`。
  if (state.zombie) return 'failed|zombie'
  return `${state.status}|${row.ended_at ?? ''}`
}

function scheduleCompletion(row, previous) {
  const status = effectiveStatus(row)
  if (!status || status === 'running') return
  if ((state.completionEvents ?? {})[row.session_id] === completionStamp(row)) return

  const sawRunning = String(previous ?? '').startsWith('running|') ||
    state.pendingRunning.includes(row.session_id)
  if (!sawRunning) return

  const pending = state.pendingCompletions ?? (state.pendingCompletions = {})
  const stamp = completionStamp(row)
  if (pending[row.session_id]?.stamp === stamp) return
  pending[row.session_id] = { stamp, since: Date.now(), previous }
}

/** 每轮 poll 调一次：把「稳住了」的终态真正发出去。 */
function flushCompletions() {
  const pending = state.pendingCompletions
  if (!pending || !db) return
  const now = Date.now()
  for (const [sessionId, entry] of Object.entries(pending)) {
    if (now - entry.since < COMPLETION_SETTLE_MS) continue
    delete pending[sessionId]
    const row = getSessionById(db, sessionId)
    if (!row) continue
    const status = effectiveStatus(row)
    if (!status || status === 'running') continue      // 翻回运行：不是终态
    if (completionStamp(row) !== entry.stamp) continue // 又变了：下一轮重新排队
    emitCompletion(row, entry.previous)
  }
}

function emitCompletion(row, previous) {
  const status = effectiveStatus(row)
  const stamp = completionStamp(row)
  const event = status === 'failed'
    ? 'session_failed'
    : (status === 'cancelled' ? 'session_cancelled' : 'session_done')
  const record = toRecord(row, extractSession(row.messages_path, cfg))
  const summary = String(record.resultText ?? '').replace(/\s+/g, ' ').trim()

  outbox.add({
    kind: 'hook',
    body: {
      event,
      sessionId: row.session_id,
      receivedAt: new Date().toISOString(),
      payload: {
        sessionId: row.session_id,
        status,
        title: record.workspace || 'Cline',
        message: summary.slice(0, 300) || record.userPrompt || '',
        workspaceRoot: row.workspace_root,
        cwd: row.cwd
      }
    }
  })
  state.completionEvents = { ...(state.completionEvents ?? {}), [row.session_id]: stamp }
  logger.info('session completion event queued', { id: row.session_id, event })
}

/**
 * 上报一条会话快照。
 *
 * - 指纹（status + updated_at）没变就跳过：同一个快照不重复发。
 * - running 也发：手机要能看到「执行中」和最新一条用户消息；
 *   但按 RUNNING_MIN_INTERVAL_MS 节流，长会话不会把 Hub 写爆。
 */
function emitSession(row) {
  const fingerprint = fingerprintOf(row)
  const previous = state.sentSessions[row.session_id]
  if (previous === fingerprint) return false

  const sessionMeta = sessionState(row)
  const isLive = sessionMeta.status === 'running'
  const now = Date.now()
  if (isLive) {
    if (now - (runningEmitAt.get(row.session_id) ?? 0) < RUNNING_MIN_INTERVAL_MS) return false
  } else if (sessionMeta.zombie) {
    if (now - (zombieEmitAt.get(row.session_id) ?? 0) < ZOMBIE_MIN_INTERVAL_MS) return false
  }

  const extraction = extractSession(row.messages_path, cfg)
  const record = toRecord(row, extraction)
  outbox.add({ kind: 'session', body: { session: record } })

  // running → 终态：补一条完成通知（不依赖 Cline hook 是否还活着）
  if (!isLive) scheduleCompletion(row, previous)

  rememberSent(row.session_id, fingerprint)
  if (isLive) runningEmitAt.set(row.session_id, now)
  if (sessionMeta.zombie) zombieEmitAt.set(row.session_id, now)

  // 消息流跟会话快照一起收尾，避免手机停在倒数第二条
  syncTranscript(row)

  logger.info('session queued', {
    id: row.session_id,
    status: row.status,
    live: isLive,
    workspace: record.workspace,
    promptChars: record.userPrompt.length,
    resultChars: record.resultText.length,
    commands: record.metrics.commandCount
  })
  return true
}

/**
 * 一次性回填：把最近活跃的会话重新取一遍，指纹对得上就自动跳过。
 * 只在水位线迁移（state.json 里还是旧的 id 数组）之后跑一次。
 */
function backfillSessions() {
  const rows = listRecentSessions(db, BACKFILL_LIMIT)
  let emitted = 0
  for (const row of rows) {
    if (!allowedWorkspace(row)) continue
    if (emitSession(row)) emitted += 1
  }
  logger.info('session backfill done', { scanned: rows.length, emitted })
}

/**
 * 历史上报只存了「最后一条回复」，老会话在 Hub 里就剩一句话。
 * 升级后排队把最近 60 个会话的完整消息流补一遍；已经有水位线的会话会被
 * syncTranscript 直接跳过，所以重复执行只是多读几个文件。
 */
function queueTranscriptBackfill() {
  if (!db || state.transcriptBackfillDone || state.transcriptBackfill.length > 0) return
  const rows = listRecentSessions(db, TRANSCRIPT_BACKFILL_LIMIT)
  state.transcriptBackfill = rows.filter(allowedWorkspace).map((row) => row.session_id)
  if (state.transcriptBackfill.length === 0) state.transcriptBackfillDone = true
  logger.info('transcript backfill queued', { count: state.transcriptBackfill.length })
}

function drainTranscriptBackfill() {
  if (!db || state.transcriptBackfill.length === 0) return
  const batch = state.transcriptBackfill.splice(0, TRANSCRIPT_BACKFILL_PER_TICK)
  for (const sessionId of batch) {
    const row = getSessionById(db, sessionId)
    if (row) syncTranscript(row)
  }
  if (state.transcriptBackfill.length === 0) {
    state.transcriptBackfillDone = true
    logger.info('transcript backfill done')
  }
}

/** 每 runningPollIntervalMs 跑一次：只扫还在跑的会话，没新消息不发请求。 */
function syncLiveTranscripts() {
  if (!db || state.pendingRunning.length === 0) return
  let changed = false
  for (const sessionId of [...state.pendingRunning]) {
    const row = getSessionById(db, sessionId)
    if (row && syncTranscript(row)) changed = true
  }
  if (changed) saveState()
}

function pollSessions() {
  if (!db) return

  if (state.needsBackfill) {
    backfillSessions()
    state.needsBackfill = false
  }

  const rows = listSessionsSince(db, state.lastUpdatedAt, cfg.batchSize)
  for (const row of rows) {
    state.lastUpdatedAt = row.updated_at
    if (!allowedWorkspace(row)) continue
    if (effectiveStatus(row) === 'running') {
      if (!state.pendingRunning.includes(row.session_id)) state.pendingRunning.push(row.session_id)
      emitSession(row)
      continue
    }
    emitSession(row)
  }

  if (state.pendingRunning.length > 0) {
    const stillRunning = []
    for (const sessionId of state.pendingRunning) {
      const row = getSessionById(db, sessionId)
      if (!row) continue
      if (effectiveStatus(row) === 'running') {
        stillRunning.push(sessionId)
        continue
      }
      emitSession(row)
    }
    state.pendingRunning = stillRunning
  }

  flushCompletions()
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
    // 抽取规则升级（TRANSCRIPT_VERSION 变化）后旧水位线全部失效，但静止会话
    // 不会被任何扫描路径碰到 —— 必须重开一次有限回填，否则它们永远停在旧版本
    // （2026-11-02：单条上限从 2000 提到 20000 时就是这么补历史的）。
    if (state.transcriptBackfillDone &&
        Object.values(state.transcripts).some((entry) => entry?.v !== TRANSCRIPT_VERSION)) {
      state.transcriptBackfillDone = false
      logger.info('transcript version changed, re-arming backfill', { version: TRANSCRIPT_VERSION })
    }
    queueTranscriptBackfill()
    drainTranscriptBackfill()
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

async function shutdown(reason, { keepChildren = false } = {}) {
  if (shuttingDown) return
  shuttingDown = true
  logger.info('shutting down', { reason, pending: outbox.pending, keepChildren })
  // 顺序不能反：先把执行中的命令回写成 failed（手机不再卡「执行中」），
  // 再杀进程树，最后才退出。硬杀（Stop-Process / taskkill）等于跳过这一步，
  // 见 docs/interruptions.md。
  try {
    const result = await commandWorker.shutdown({ reason, keepChildren })
    if (result.interrupted.length > 0) logger.warn('in-flight commands interrupted', result)
  } catch (error) {
    logger.error('command shutdown failed', { message: error.message })
  }
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

server = await startHookServer({
  host: cfg.hookHost,
  port: cfg.hookPort,
  onHook,
  // 本机控制口：`npm run stop` / `npm run restart` 走这里，触发的是优雅关闭。
  // options 目前只有 keepChildren（`npm run restart -- --keep-session`）。
  onStop: (reason, options) => { void shutdown(reason, options) },
  logger
})

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

// 启动时先对一次账：上次 bridge 崩溃/被重启时留下的 running 命令，
// 会话已经翻成 failed，这里负责把命令状态也收尾（不杀进程，只在进程确实不在时回写）。
if (!ONCE) {
  commandWorker.reconcile()
    .then((result) => logger.info('command reconcile on boot', result))
    .catch((error) => logger.warn('command reconcile on boot failed', { message: error.message }))
}

await tick()

if (ONCE) {
  await shutdown('once')
} else {
  setInterval(tick, cfg.pollIntervalMs)
  // 消息级刷新比会话快照更勤：3s 一次，没新消息时只是读文件 + 内存比较。
  setInterval(() => {
    try {
      syncLiveTranscripts()
    } catch (error) {
      logger.error('live transcript sync failed', { message: error.message })
    }
  }, cfg.runningPollIntervalMs)
  process.on('SIGINT', () => shutdown('SIGINT'))
  process.on('SIGTERM', () => shutdown('SIGTERM'))
}
