import crypto from 'node:crypto'

import { HttpError } from '../http.js'
import { optionalString, requireString } from '../util.js'

/**
 * 附件（App → Hub → bridge）。
 *
 * 传输格式是 **base64 JSON**，不是 multipart：Hub 是零框架的 `node:http`，
 * 不引 multer / busboy 就没有 multipart 解析；JSON 走现成的 `readJsonBody()`
 * 与 `HUB_MAX_BODY_BYTES` 限流，出错路径只有一条（ADR-52）。
 *
 * 内容存 Postgres 的 bytea：Docker 里没有可信的持久目录，跟着数据库备份最省事。
 */

/** Windows 不接受的文件名字符，落库前统一换掉（展示与 bridge 落盘都用这个名字）。 */
const UNSAFE_NAME = /[\u0000-\u001f<>:"|?*]/g

/** 原文件名只留最后一段：手机选文件时可能带 `content://…/report.pdf` 这样的路径。 */
export function safeAttachmentName(raw, fallback = 'attachment') {
  const text = typeof raw === 'string' ? raw : ''
  const base = text.split(/[\\/]/).pop() ?? ''
  const cleaned = base
    .replace(UNSAFE_NAME, '_')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/^\.+/, '')
    .slice(0, 120)
  return cleaned || fallback
}

/**
 * base64 → Buffer，顺便把「超限」与「不是 base64」分清楚：
 * 前者是 413（客户端该提示文件太大），后者是 400（客户端 bug）。
 */
export function decodeAttachmentData(value, maxBytes) {
  if (typeof value !== 'string' || value.trim() === '') {
    throw new HttpError(400, 'data must be a base64 string', 'invalid_field')
  }
  const compact = value.replace(/\s+/g, '')
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(compact) || compact.length % 4 !== 0) {
    throw new HttpError(400, 'data is not valid base64', 'invalid_field')
  }
  // 先按长度估算，避免为了抛 413 先把几十 MB 解出来（base64 ≈ 4/3 原始大小）。
  if (compact.length > Math.ceil(maxBytes / 3) * 4) {
    throw new HttpError(
      413,
      `attachment larger than ${maxBytes} bytes`,
      'attachment_too_large'
    )
  }
  const buffer = Buffer.from(compact, 'base64')
  if (buffer.length === 0) throw new HttpError(400, 'data decoded to 0 bytes', 'invalid_field')
  if (buffer.length > maxBytes) {
    throw new HttpError(
      413,
      `attachment larger than ${maxBytes} bytes`,
      'attachment_too_large'
    )
  }
  return buffer
}

/**
 * 库里的一行 → 客户端看到的元数据（**不含内容**，列表里不会背大字段）。
 *
 * `createdAt` 是**入库时间**（附件落进 Hub 的时刻，不是命令下发时间）：
 * 手机上要能看出「这份文件是哪天传上来的」，也是以后做保留策略
 * （按年龄清理）时唯一的依据 —— 现在只记录、不清理。
 */
export function toAttachment(row) {
  if (!row) return null
  return {
    id: row.id,
    name: row.name,
    mimeType: row.mime_type,
    byteSize: row.byte_size,
    createdAt: row.created_at ?? null
  }
}

export function createAttachmentRoutes({ db, logger, config }) {
  const maxBytes =
    Number.isFinite(Number(config?.maxAttachmentBytes)) && Number(config.maxAttachmentBytes) > 0
      ? Number(config.maxAttachmentBytes)
      : 8 * 1024 * 1024
  /** base64 膨胀 4/3，再留一点 JSON 外壳的余量。 */
  const bodyLimit = Math.ceil(maxBytes / 3) * 4 + 8192

  async function assertDevice(deviceId) {
    const row = await db.one(`select id from clients where id = $1 and role = 'device'`, [deviceId])
    if (!row) throw new HttpError(400, `unknown device: ${deviceId}`, 'unknown_device')
    return row.id
  }

  return [
    {
      method: 'POST',
      pattern: '/api/v1/attachments',
      auth: 'app',
      bodyLimit,
      async handler({ body, client }) {
        const deviceId = await assertDevice(requireString(body.deviceId, 'deviceId', { max: 100 }))
        const name = safeAttachmentName(body.name)
        const mimeType =
          optionalString(body.mimeType, 'mimeType', 120) ?? 'application/octet-stream'
        const data = decodeAttachmentData(body.data, maxBytes)
        const sha256 = crypto.createHash('sha256').update(data).digest('hex')

        // 同设备 + 同名 + 同内容直接复用：手机连点两次「下发」不该存两份。
        const existing = await db.one(
          `select id, name, mime_type, byte_size, created_at from attachments
           where device_id = $1 and sha256 = $2 and name = $3
           order by created_at desc
           limit 1`,
          [deviceId, sha256, name]
        )
        if (existing) {
          logger.info('attachment reused', { id: existing.id, deviceId, name })
          return { ok: true, attachment: toAttachment(existing), reused: true }
        }

        const id = `att_${crypto.randomBytes(8).toString('hex')}`
        const row = await db.one(
          `insert into attachments (id, device_id, name, mime_type, byte_size, sha256, data, uploaded_by)
           values ($1, $2, $3, $4, $5, $6, $7, $8)
           returning id, name, mime_type, byte_size, created_at`,
          [id, deviceId, name, mimeType, data.length, sha256, data, client.id]
        )
        logger.info('attachment stored', {
          id,
          deviceId,
          name,
          bytes: data.length,
          uploadedBy: client.id
        })
        return { ok: true, attachment: toAttachment(row) }
      }
    },

    {
      // bridge 用 device token 下载；App 也能取（比如以后要预览）。
      method: 'GET',
      pattern: '/api/v1/attachments/:id',
      auth: 'any',
      async handler({ params, res, client }) {
        const row = await db.one('select * from attachments where id = $1', [params.id])
        if (!row) throw new HttpError(404, 'attachment not found', 'not_found')
        // 与命令详情同一条规则：device 只能碰自己的行（ADR-43）。
        if (client.role === 'device' && row.device_id !== client.id) {
          throw new HttpError(403, 'attachment belongs to another device', 'forbidden')
        }
        const bytes = Buffer.isBuffer(row.data) ? row.data : Buffer.from(row.data ?? '')
        res.writeHead(200, {
          'content-type': row.mime_type || 'application/octet-stream',
          'content-length': bytes.length,
          'content-disposition': `attachment; filename*=UTF-8''${encodeURIComponent(row.name)}`,
          'cache-control': 'private, max-age=600'
        })
        res.end(bytes)
        return undefined // 已经自己写完响应（同 SSE 的约定）
      }
    }
  ]
}
