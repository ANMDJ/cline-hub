import fs from 'node:fs'
import path from 'node:path'
import { DatabaseSync } from 'node:sqlite'

const SESSION_COLUMNS = `session_id, source, status, exit_code, provider, model, cwd,
  workspace_root, prompt, messages_path, transcript_path, started_at, ended_at, updated_at`

export function sessionsDbPath(dataDir) {
  return path.join(dataDir, 'db', 'sessions.db')
}

/**
 * Read-only handle on the DB shared by the Cline plugin and CLI.
 * Never write: Cline owns this file.
 */
export function openSessionsDb(dataDir) {
  const file = sessionsDbPath(dataDir)
  if (!fs.existsSync(file)) {
    throw new Error(`sessions.db not found: ${file}`)
  }
  const db = new DatabaseSync(file, { readOnly: true })
  try {
    db.exec('PRAGMA busy_timeout = 3000')
  } catch {
    // pragma may be rejected on some read-only handles; not fatal
  }
  return db
}

/** Incremental scan by updated_at watermark (ascending). */
export function listSessionsSince(db, sinceIso, limit = 20) {
  return db
    .prepare(
      `SELECT ${SESSION_COLUMNS} FROM sessions
       WHERE updated_at > ?
       ORDER BY updated_at ASC
       LIMIT ?`
    )
    .all(sinceIso, limit)
}

export function getSessionById(db, sessionId) {
  const row = db
    .prepare(`SELECT ${SESSION_COLUMNS} FROM sessions WHERE session_id = ?`)
    .get(sessionId)
  return row ?? null
}

/**
 * 最近活跃的会话（不看水位线），用于一次性回填。
 *
 * 水位线只会向前推进：旧版本对"已上报过的 session_id"是直接静默跳过的，
 * 这些会话的 updated_at 早就落到水位线以下，再也不会被 listSessionsSince
 * 扫到。升级后靠这个查询把它们的最新快照补推一遍。
 */
export function listRecentSessions(db, limit = 100) {
  return db
    .prepare(
      `SELECT ${SESSION_COLUMNS} FROM sessions
       ORDER BY updated_at DESC
       LIMIT ?`
    )
    .all(limit)
}
