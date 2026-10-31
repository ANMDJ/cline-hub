import crypto from 'node:crypto'

import { HttpError } from '../http.js'
import { requireString, optionalString, limitFrom } from '../util.js'

const MODES = new Set(['plan', 'act', 'yolo'])
const REPORTABLE = new Set(['running', 'done', 'failed', 'cancelled'])

function toCommand(row) {
  return {
    id: row.id,
    deviceId: row.device_id,
    prompt: row.prompt,
    mode: row.mode,
    workspace: row.workspace,
    status: row.status,
    requestedBy: row.requested_by,
    resultText: row.result_text,
    errorText: row.error_text,
    createdAt: row.created_at,
    deliveredAt: row.delivered_at,
    startedAt: row.started_at,
    finishedAt: row.finished_at
  }
}

export function createCommandRoutes({ db, logger, sse }) {
  async function assertDevice(deviceId) {
    const row = await db.one(`select id from clients where id = $1 and role = 'device'`, [deviceId])
    if (!row) throw new HttpError(400, `unknown device: ${deviceId}`, 'unknown_device')
    return row.id
  }

  function deviceScope(client, source) {
    if (client.role === 'device') return client.id
    return requireString(source, 'deviceId', { max: 100 })
  }

  return [
    {
      method: 'POST',
      pattern: '/api/v1/commands',
      auth: 'app',
      async handler({ body, client }) {
        const deviceId = await assertDevice(requireString(body.deviceId, 'deviceId', { max: 100 }))
        const prompt = requireString(body.prompt, 'prompt', { max: 4000 })
        const mode = optionalString(body.mode, 'mode', 10) ?? 'plan'
        if (!MODES.has(mode)) {
          throw new HttpError(400, `mode must be one of ${[...MODES].join(', ')}`, 'invalid_field')
        }
        const workspace = optionalString(body.workspace, 'workspace', 1000)
        const id = `cmd_${crypto.randomBytes(6).toString('hex')}`

        const row = await db.one(
          `insert into commands (id, device_id, prompt, mode, workspace, requested_by)
           values ($1, $2, $3, $4, $5, $6)
           returning *`,
          [id, deviceId, prompt, mode, workspace, client.id]
        )

        logger.info('command queued', { id, deviceId, mode, requestedBy: client.id })
        sse.broadcast('command', toCommand(row))
        return { ok: true, command: toCommand(row) }
      }
    },

    {
      method: 'GET',
      pattern: '/api/v1/commands',
      auth: 'any',
      async handler({ url }) {
        const limit = limitFrom(url, 50, 200)
        const status = optionalString(url.searchParams.get('status'), 'status', 20)
        const deviceId = optionalString(url.searchParams.get('deviceId'), 'deviceId', 100)

        const where = []
        const values = []
        if (status) {
          values.push(status)
          where.push(`status = $${values.length}`)
        }
        if (deviceId) {
          values.push(deviceId)
          where.push(`device_id = $${values.length}`)
        }
        values.push(limit)

        const rows = await db.many(
          `select * from commands
           ${where.length ? 'where ' + where.join(' and ') : ''}
           order by created_at desc
           limit $${values.length}`,
          values
        )
        return { ok: true, items: rows.map(toCommand) }
      }
    },

    {
      // must be declared before /:id so "pending" is not parsed as an id
      method: 'GET',
      pattern: '/api/v1/commands/pending',
      auth: 'device',
      async handler({ url, client }) {
        const deviceId = deviceScope(client, url.searchParams.get('deviceId'))
        const limit = limitFrom(url, 10, 50)

        const rows = await db.tx(async (connection) => {
          const picked = await connection.query(
            `select * from commands
             where device_id = $1 and status = 'pending'
             order by created_at asc
             limit $2
             for update skip locked`,
            [deviceId, limit]
          )
          if (picked.rows.length === 0) return []
          const ids = picked.rows.map((row) => row.id)
          await connection.query(
            `update commands
             set status = 'delivered', delivered_at = now()
             where id = any($1::text[])`,
            [ids]
          )
          return picked.rows.map((row) => ({ ...row, status: 'delivered' }))
        })

        if (rows.length > 0) {
          logger.info('commands delivered', { deviceId, count: rows.length })
          for (const row of rows) sse.broadcast('command.update', toCommand(row))
        }

        return { ok: true, deviceId, items: rows.map(toCommand) }
      }
    },

    {
      method: 'GET',
      pattern: '/api/v1/commands/:id',
      auth: 'any',
      async handler({ params }) {
        const row = await db.one('select * from commands where id = $1', [params.id])
        if (!row) throw new HttpError(404, 'command not found', 'not_found')
        return { ok: true, command: toCommand(row) }
      }
    },

    {
      // the bridge reports progress / final result here
      method: 'PATCH',
      pattern: '/api/v1/commands/:id',
      auth: 'device',
      async handler({ params, body, client }) {
        const existing = await db.one('select * from commands where id = $1', [params.id])
        if (!existing) throw new HttpError(404, 'command not found', 'not_found')
        if (client.role === 'device' && existing.device_id !== client.id) {
          throw new HttpError(403, 'command belongs to another device', 'forbidden')
        }

        const status = requireString(body.status, 'status', { max: 20 })
        if (!REPORTABLE.has(status)) {
          throw new HttpError(400, `status must be one of ${[...REPORTABLE].join(', ')}`, 'invalid_field')
        }
        const resultText = optionalString(body.resultText, 'resultText', 20000)
        const errorText = optionalString(body.errorText, 'errorText', 4000)

        const updated = await db.one(
          `update commands set
             status      = $2,
             result_text = coalesce($3, result_text),
             error_text  = coalesce($4, error_text),
             started_at  = case when $2 = 'running' and started_at is null then now() else started_at end,
             finished_at = case when $2 in ('done', 'failed', 'cancelled') then now() else finished_at end
           where id = $1
           returning *`,
          [params.id, status, resultText, errorText]
        )

        logger.info('command updated', { id: params.id, status })
        sse.broadcast('command.update', toCommand(updated))
        return { ok: true, command: toCommand(updated) }
      }
    }
  ]
}
