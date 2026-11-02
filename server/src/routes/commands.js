import crypto from 'node:crypto'

import { HttpError } from '../http.js'
import { requireString, optionalString, limitFrom, isoOrNull } from '../util.js'

const MODES = new Set(['plan', 'act', 'yolo'])
const REPORTABLE = new Set(['running', 'done', 'failed', 'cancelled'])

/**
 * `pid` 来自 bridge，必须是正整数。这里不信任客户端：
 * 传 `"123"` 这种字符串也接受（JSON 里数字更常见），非法值直接 400。
 */
function optionalPid(value) {
  if (value === undefined || value === null || value === '') return null
  const num = Number(value)
  if (!Number.isInteger(num) || num <= 0 || num > 2147483647) {
    throw new HttpError(400, 'pid must be a positive integer', 'invalid_field')
  }
  return num
}

function toCommand(row) {
  return {
    id: row.id,
    deviceId: row.device_id,
    prompt: row.prompt,
    mode: row.mode,
    workspace: row.workspace,
    /** 有值时 bridge 会用 `cline --id` 续在这个会话里；空表示新开会话。 */
    sessionId: row.session_id ?? null,
    status: row.status,
    requestedBy: row.requested_by,
    /** 执行器 + 进程身份（bridge 上报）：手机上可直接核对/复制排查命令。 */
    runner: row.runner ?? null,
    pid: row.pid ?? null,
    pidStartedAt: row.pid_started_at ?? null,
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
        const sessionId = optionalString(body.sessionId, 'sessionId', 200)
        const id = `cmd_${crypto.randomBytes(6).toString('hex')}`

        const row = await db.one(
          `insert into commands (id, device_id, prompt, mode, workspace, session_id, requested_by)
           values ($1, $2, $3, $4, $5, $6, $7)
           returning *`,
          [id, deviceId, prompt, mode, workspace, sessionId, client.id]
        )

        logger.info('command queued', { id, deviceId, mode, sessionId, requestedBy: client.id })
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
        // bridge 新开会话后回写会话 ID；coalesce 保证只写一次，后续上报不会把它清掉。
        const sessionId = optionalString(body.sessionId, 'sessionId', 200)
        // 进程身份：pid 与 pidStartedAt 成对上报。缺启动时间的 pid 在 App 里只做展示，
        // 不得据此杀进程（Windows 会复用 PID，见 ADR-33）。
        const pid = optionalPid(body.pid)
        const pidStartedAt = isoOrNull(body.pidStartedAt)
        const runner = optionalString(body.runner, 'runner', 20)

        const updated = await db.one(
          `update commands set
             status      = $2,
             result_text = coalesce($3, result_text),
             error_text  = coalesce($4, error_text),
             session_id  = coalesce($5, session_id),
             pid            = coalesce($6, pid),
             pid_started_at = coalesce($7::timestamptz, pid_started_at),
             runner         = coalesce($8, runner),
             started_at  = case when $2 = 'running' and started_at is null then now() else started_at end,
             finished_at = case when $2 in ('done', 'failed', 'cancelled') then now() else finished_at end
           where id = $1
           returning *`,
          [params.id, status, resultText, errorText, sessionId, pid, pidStartedAt, runner]
        )

        logger.info('command updated', { id: params.id, status })
        sse.broadcast('command.update', toCommand(updated))
        return { ok: true, command: toCommand(updated) }
      }
    }
  ]
}
