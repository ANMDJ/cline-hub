import crypto from 'node:crypto'

export const hashToken = (token) => crypto.createHash('sha256').update(token).digest('hex')

/** clh_ + 32 hex chars. Only the sha256 hash is stored server side. */
export function newToken() {
  return `clh_${crypto.randomBytes(16).toString('hex')}`
}

const CACHE_TTL_MS = 60_000
const TOUCH_INTERVAL_MS = 60_000

/**
 * Resolves `Authorization: Bearer <token>` to a client row.
 * Admin token is a plain env compare (constant time-ish) and never hits the DB.
 */
export function createAuth({ db, adminToken, logger }) {
  const cache = new Map()

  async function resolve(token) {
    if (!token) return null

    if (adminToken && token.length === adminToken.length) {
      const a = Buffer.from(token)
      const b = Buffer.from(adminToken)
      if (a.length === b.length && crypto.timingSafeEqual(a, b)) {
        return { id: 'admin', name: 'admin', role: 'admin' }
      }
    }

    const key = hashToken(token)
    const cached = cache.get(key)
    if (cached && Date.now() - cached.at < CACHE_TTL_MS) {
      void touch(key, cached.client)
      return cached.client
    }

    const row = await db.one('select id, name, role from clients where token_hash = $1', [key])
    if (!row) {
      cache.delete(key)
      return null
    }

    // touchedAt 表示「上次写库时间」，首次必须给 0：否则 Date.now() - last 恒为 0，
    // 永远落在节流窗口内，last_seen_at 就一直是 null（实测踩过）。
    cache.set(key, { at: Date.now(), touchedAt: 0, client: row })
    void touch(key, row)
    return row
  }

  /** last_seen_at 只是运维信号：同一个 client 60 秒最多写一次。 */
  async function touch(key, client) {
    if (!client?.id || client.id === 'admin') return
    const entry = cache.get(key)
    const last = entry?.touchedAt ?? 0
    if (Date.now() - last < TOUCH_INTERVAL_MS) return
    if (entry) entry.touchedAt = Date.now()
    try {
      await db.query('update clients set last_seen_at = now() where id = $1', [client.id])
    } catch (error) {
      logger.debug('touch failed', { message: error.message })
    }
  }

  return { resolve }
}
