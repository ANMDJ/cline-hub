import {
  optionalString,
  isoOrNull,
  limitFrom,
  resolveDeviceId,
  readDeviceScope,
  toJsonObject
} from '../util.js'

function workspaceFromPayload(payload) {
  const candidate =
    payload?.workspaceRoots?.[0] ??
    payload?.workspace?.rootPath ??
    payload?.workspaceRoot ??
    payload?.cwd ??
    null
  if (typeof candidate !== 'string' || !candidate.trim()) return null
  return candidate.trim().slice(0, 1000)
}

export function createHookRoutes({ db, logger, sse }) {
  return [
    {
      method: 'POST',
      pattern: '/api/v1/hooks',
      auth: 'device',
      async handler({ body, client }) {
        const deviceId = resolveDeviceId(client, body)
        const payload = toJsonObject(body.payload)
        const event = optionalString(body.event, 'event', 200) ?? 'unknown'
        const title = optionalString(payload.title, 'payload.title', 300)
        const text = optionalString(payload.message ?? payload.body ?? payload.prompt, 'payload.message', 4000)
        const receivedAt = isoOrNull(body.receivedAt)
        // bridge 的完成通知会把会话 id 带上；Cline 自己的 hook 没有，留 null。
        const sessionId = optionalString(body.sessionId ?? payload.sessionId, 'sessionId', 200)

        const row = await db.one(
          `insert into hooks (device_id, event, workspace, title, body, payload, session_id, received_at)
           values ($1, $2, $3, $4, $5, $6::jsonb, $7, coalesce($8::timestamptz, now()))
           returning id, received_at`,
          [deviceId, event, workspaceFromPayload(payload), title, text, JSON.stringify(payload), sessionId, receivedAt]
        )

        logger.info('hook stored', { deviceId, event, id: row.id, sessionId })

        sse.broadcast('hook', {
          id: row.id,
          deviceId,
          event,
          title,
          body: text ? text.slice(0, 300) : null,
          sessionId,
          receivedAt: row.received_at
        })

        return { ok: true, id: row.id }
      }
    },

    {
      method: 'GET',
      pattern: '/api/v1/hooks',
      auth: 'any',
      async handler({ url, client }) {
        const limit = limitFrom(url, 50, 200)
        const beforeId = Number(url.searchParams.get('beforeId') ?? '')
        const deviceId = readDeviceScope(client, url.searchParams.get('deviceId'))

        const where = []
        const values = []
        if (Number.isInteger(beforeId) && beforeId > 0) {
          values.push(beforeId)
          where.push(`id < $${values.length}`)
        }
        if (deviceId) {
          values.push(deviceId)
          where.push(`device_id = $${values.length}`)
        }
        values.push(limit)

        const rows = await db.many(
          `select id, device_id, event, workspace, title, body, session_id, received_at
           from hooks
           ${where.length ? 'where ' + where.join(' and ') : ''}
           order by id desc
           limit $${values.length}`,
          values
        )

        return {
          ok: true,
          items: rows.map((row) => ({
            id: row.id,
            deviceId: row.device_id,
            event: row.event,
            workspace: row.workspace,
            title: row.title,
            body: row.body,
            sessionId: row.session_id,
            receivedAt: row.received_at
          })),
          nextBeforeId: rows.length === limit ? rows.at(-1).id : null
        }
      }
    }
  ]
}
