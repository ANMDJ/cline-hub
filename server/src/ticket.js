/**
 * SSE 短期票据（P41 / ADR-64）。
 *
 * 背景：`EventSource` 不能带请求头，所以历史上 `GET /api/v1/events?token=clh_…`
 * 直接把**长期** token 写进了 URL；URL 会被 Caddy access log、抓包、崩溃栈原样
 * 记下来（docs/security-review.md §3.1）。
 *
 * 做法：手机先用正常 Bearer 调 `POST /api/v1/sse-ticket`，拿到一张 60 秒内有效、
 * **一次性**的票据，再用 `?ticket=` 连 SSE。进程内只存 `sha256(ticket)`，日志里
 * 出现的也只是 `clt_…`，重放拿不到第二次。
 *
 * 为什么不用数据库：票据活 60 秒、单进程部署（见 ADR-64），落库只会多一次写；
 * 进程重启让票据失效是**期望行为**（重连时会重新换一张）。
 */
import crypto from 'node:crypto'

import { hashToken } from './auth.js'

/** 和 token 的 `clh_` 前缀分开：日志里一眼能看出这不是可长期使用的凭据。 */
export const TICKET_PREFIX = 'clt_'

export function createSseTickets({ ttlMs = 60_000, sweepMs = 30_000, logger, now = Date.now } = {}) {
  const ttl = Number.isFinite(ttlMs) && ttlMs > 0 ? ttlMs : 60_000
  const lifetime = Math.round(ttl / 1000)
  const tickets = new Map() // sha256(ticket) -> { client, expiresAt }

  const timer = setInterval(() => {
    const at = now()
    for (const [key, entry] of tickets) {
      if (entry.expiresAt <= at) tickets.delete(key)
    }
  }, sweepMs)
  timer.unref?.()

  return {
    /** 只返回明文一次；库里（这里是内存）只留 hash。 */
    issue(client) {
      if (!client?.id) throw new Error('sse ticket needs a client')
      const ticket = `${TICKET_PREFIX}${crypto.randomBytes(24).toString('hex')}`
      const expiresAt = now() + ttl
      tickets.set(hashToken(ticket), {
        client: { id: client.id, name: client.name ?? '', role: client.role },
        expiresAt
      })
      return {
        ticket,
        expiresInSec: lifetime,
        expiresAt: new Date(expiresAt).toISOString()
      }
    },

    /** 一次性：claim 成功即从表里删掉，重放 / 猜中都要拿不到第二次。 */
    claim(raw) {
      const value = String(raw ?? '').trim()
      if (!value) return null
      const key = hashToken(value)
      const entry = tickets.get(key)
      if (!entry) return null
      tickets.delete(key)
      if (entry.expiresAt <= now()) {
        logger?.debug?.('sse ticket expired', { key })
        return null
      }
      return entry.client
    },

    get size() {
      return tickets.size
    },

    /** 只给测试 / 关停机用，正常不需要。 */
    close() {
      clearInterval(timer)
      tickets.clear()
    }
  }
}
