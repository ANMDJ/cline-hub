import crypto from 'node:crypto'

import { HttpError } from '../http.js'
import { toAttachment } from './attachments.js'
import {
  requireString,
  optionalString,
  limitFrom,
  isoOrNull,
  normalizeFsPath,
  readDeviceScope
} from '../util.js'

const MODES = new Set(['plan', 'act', 'yolo'])
const REPORTABLE = new Set(['running', 'done', 'failed', 'cancelled'])

/**
 * 已经结束的状态。`cancelling` 不算：那是「执行中、但用户要求停」，
 * 此时 bridge 还没杀完进程，允许它继续回写取消结果。
 */
const FINISHED = new Set(['done', 'failed', 'cancelled'])

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

export function toCommand(row) {
  return {
    id: row.id,
    deviceId: row.device_id,
    prompt: row.prompt,
    mode: row.mode,
    workspace: normalizeFsPath(row.workspace),
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
    finishedAt: row.finished_at,
    /** 手机端点「取消」的时间；null 表示没人取消过。 */
    cancelRequestedAt: row.cancel_requested_at ?? null,
    /**
     * 租约到期时间（P42）：bridge 每 30 秒续一次。手机上不直接展示，
     * 但排查「为什么命令自己变成 failed」时一眼能看到是不是执行侧失联。
     */
    leaseExpiresAt: row.lease_expires_at ?? null,
    /**
     * 随命令带过去的附件（文件 / 图片）：只有元数据，内容由 bridge 按 id 下载。
     * 列表与详情都返回它 —— 体积很小，不违反 ADR-2「列表不带大字段」。
     */
    attachment: toAttachment(row.attachment ?? null)
  }
}

/**
 * 把 `attachment_id` 换成附件元数据。
 *
 * 为什么不直接 join：`/commands/pending` 用 `for update skip locked` 认领，
 * 外连接（`left join`）在 Postgres 里不能配 `for update`（要写 `of c`，容易写错），
 * 一条朴素的两段查询更不容易出事故，而且附件数量远小于命令行数。
 *
 * 导出给 `src/lease.js` 复用：租约回收也要广播**带附件信息**的 command.update，
 * 否则手机上的附件卡片会在命令失败时凭空消失。
 */
export async function attachMetadata(db, rows) {
  const list = Array.isArray(rows) ? rows : [rows]
  const ids = [...new Set(list.map((row) => row?.attachment_id).filter(Boolean))]
  if (ids.length === 0) return list.map((row) => (row ? { ...row, attachment: null } : row))
  const found = await db.many(
    'select id, name, mime_type, byte_size, created_at from attachments where id = any($1::text[])',
    [ids]
  )
  const byId = new Map(found.map((item) => [item.id, item]))
  return list.map((row) =>
    row ? { ...row, attachment: byId.get(row.attachment_id) ?? null } : row
  )
}


export function createCommandRoutes({ db, logger, sse, config = {} }) {
  /**
   * 租约时长（P42）：认领 / 心跳 / 回写 running 都用同一个值，
   * 否则「续租一次能撑多久」在三个地方各说一套，排查时对不上。
   */
  const leaseSec =
    Number.isInteger(config.commandLeaseSec) && config.commandLeaseSec > 0
      ? config.commandLeaseSec
      : 120

  async function assertDevice(deviceId) {
    const row = await db.one(`select id from clients where id = $1 and role = 'device'`, [deviceId])
    if (!row) throw new HttpError(400, `unknown device: ${deviceId}`, 'unknown_device')
    return row.id
  }

  /** 本模块统一走模块级 `attachMetadata`：租约回收也用它，形状必须一致。 */
  function withAttachments(rows) {
    return attachMetadata(db, rows)
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
        const mode = optionalString(body.mode, 'mode', 10) ?? 'plan'
        if (!MODES.has(mode)) {
          throw new HttpError(400, `mode must be one of ${[...MODES].join(', ')}`, 'invalid_field')
        }
        const workspace = normalizeFsPath(optionalString(body.workspace, 'workspace', 1000))
        const sessionId = optionalString(body.sessionId, 'sessionId', 200)

        /**
         * 附件（P38）：可以先传文件、再在输入框写一句「要对它做什么」，也可以只发文件。
         * 所以「必须带 prompt」的规则放宽成「prompt 或 attachmentId 至少一个」；
         * 只发文件时 prompt 落成空串，由 bridge 自己补一句「先读这个文件」。
         */
        const attachmentId = optionalString(body.attachmentId, 'attachmentId', 80)
        const prompt = attachmentId
          ? (optionalString(body.prompt, 'prompt', 4000) ?? '')
          : requireString(body.prompt, 'prompt', { max: 4000 })

        if (attachmentId) {
          const attachment = await db.one(
            'select id, device_id from attachments where id = $1',
            [attachmentId]
          )
          if (!attachment) {
            throw new HttpError(400, `unknown attachment: ${attachmentId}`, 'invalid_field')
          }
          // 附件必须发给「它被上传时指定的那台电脑」：否则 App 能借别的设备的附件跑本机文件。
          if (attachment.device_id !== deviceId) {
            throw new HttpError(403, 'attachment belongs to another device', 'forbidden')
          }
        }

        const id = `cmd_${crypto.randomBytes(6).toString('hex')}`

        const row = await db.one(
          `insert into commands (id, device_id, prompt, mode, workspace, session_id, requested_by, attachment_id)
           values ($1, $2, $3, $4, $5, $6, $7, $8)
           returning *`,
          [id, deviceId, prompt, mode, workspace, sessionId, client.id, attachmentId]
        )
        const [item] = await withAttachments([row])

        logger.info('command queued', {
          id,
          deviceId,
          mode,
          sessionId,
          attachmentId: attachmentId ?? null,
          requestedBy: client.id
        })
        sse.broadcast('command', toCommand(item))
        return { ok: true, command: toCommand(item) }
      }
    },

    {
      method: 'GET',
      pattern: '/api/v1/commands',
      auth: 'any',
      async handler({ url, client }) {
        const limit = limitFrom(url, 50, 200)
        const status = optionalString(url.searchParams.get('status'), 'status', 20)
        // device token 只能看自己的命令；app / admin 不传 deviceId 就是全部（ADR-43）。
        const deviceId = readDeviceScope(client, url.searchParams.get('deviceId'))

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
        return { ok: true, items: (await withAttachments(rows)).map(toCommand) }
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
             set status = 'delivered', delivered_at = now(),
                 -- 租约从认领这一刻开始算：bridge 崩在 spawn 之前也能被回收（P42）
                 lease_expires_at = now() + make_interval(secs => $2::int)
             where id = any($1::text[])`,
            [ids, leaseSec]
          )
          return picked.rows.map((row) => ({ ...row, status: 'delivered' }))
        })

        const items = await withAttachments(rows)
        if (items.length > 0) {
          logger.info('commands delivered', { deviceId, count: items.length })
          for (const row of items) sse.broadcast('command.update', toCommand(row))
        }

        return { ok: true, deviceId, items: items.map(toCommand) }
      }
    },

    {
      method: 'GET',
      pattern: '/api/v1/commands/:id',
      auth: 'any',
      async handler({ params, client }) {
        const row = await db.one('select * from commands where id = $1', [params.id])
        if (!row) throw new HttpError(404, 'command not found', 'not_found')
        if (client.role === 'device' && row.device_id !== client.id) {
          throw new HttpError(403, 'command belongs to another device', 'forbidden')
        }
        const [item] = await withAttachments([row])
        return { ok: true, command: toCommand(item) }
      }
    },

    {
      /**
       * 手机端取消一条命令（P14）。
       *
       * 分两种情况，客户端只看返回的 status：
       *   * `pending` / `delivered` → 直接 `cancelled`（bridge 还没 spawn，不用杀进程）；
       *   * `running` → `cancelling`，bridge 每 5 秒按 `status=cancelling` 拉一次，
       *     按 commandId 精确杀进程树后再回写 `cancelled`（ADR-40）。
       * 已经结束的命令返回 409：取消不是幂等状态翻转，别让 UI 把历史结果抹掉。
       */
      method: 'POST',
      pattern: '/api/v1/commands/:id/cancel',
      auth: 'app',
      async handler({ params, client }) {
        const existing = await db.one('select * from commands where id = $1', [params.id])
        if (!existing) throw new HttpError(404, 'command not found', 'not_found')
        if (FINISHED.has(existing.status)) {
          throw new HttpError(409, `command already ${existing.status}`, 'already_finished')
        }

        const updated = await db.one(
          `update commands set
             status = case
                        when status in ('pending', 'delivered') then 'cancelled'
                        else 'cancelling'
                      end,
             cancel_requested_at = coalesce(cancel_requested_at, now()),
             error_text = case
                            when status in ('pending', 'delivered')
                              then coalesce(error_text, '已取消：手机端在命令开始前取消。')
                            else error_text
                          end,
             finished_at = case
                             when status in ('pending', 'delivered') then now()
                             else finished_at
                           end,
             -- 直接取消（还没开跑）就不用再等心跳了；cancelling 保留租约，
             -- 等 bridge 杀完进程回写 cancelled，或租约过期由 Hub 收尾（P42）。
             lease_expires_at = case
                                  when status in ('pending', 'delivered') then null
                                  else lease_expires_at
                                end
           where id = $1
           returning *`,
          [params.id]
        )

        logger.info('command cancel requested', {
          id: params.id,
          from: existing.status,
          to: updated.status,
          requestedBy: client.id
        })
        const [item] = await withAttachments([updated])
        sse.broadcast('command.update', toCommand(item))
        return { ok: true, command: toCommand(item) }
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

        /**
         * 命令在开始执行前就被取消（status 已是 `cancelled`）：
         * bridge 可能已经把 spawn 发出去了，紧接着会报 running / done。
         * 这里一律原样返回，不让「已取消」被翻回「已完成」——
         * 否则用户点了取消，手机上却看到一条成功的命令（ADR-40）。
         */
        if (existing.status === 'cancelled') {
          logger.info('command update ignored: already cancelled', {
            id: params.id,
            reported: body.status ?? null
          })
          const [ignored] = await withAttachments([existing])
          return { ok: true, command: toCommand(ignored), ignored: true }
        }

        const status = requireString(body.status, 'status', { max: 20 })
        if (!REPORTABLE.has(status)) {
          throw new HttpError(400, `status must be one of ${[...REPORTABLE].join(', ')}`, 'invalid_field')
        }
        /**
         * 租约回收（P42）把失联命令置成 failed 之后，原来的 bridge 可能又活过来补报
         * running（机器休眠醒来 / 网络恢复）。**终态不再接受 running**：
         * 否则手机上「失败」会被翻回「执行中」，而结果永远不会再回来。
         * 真正的重试是用户重新下发一条新命令，不是复活旧命令。
         */
        if (status === 'running' && FINISHED.has(existing.status)) {
          logger.info('command update ignored: already finished', {
            id: params.id,
            was: existing.status,
            reported: status
          })
          const [ignored] = await withAttachments([existing])
          return { ok: true, command: toCommand(ignored), ignored: true }
        }
        /**
         * bridge 的 pid / sessionId 是「running」时补报的；如果用户已经取消
         * （cancelling），这次补报不能把状态覆盖回 running，否则取消信号就丢了。
         */
        const effectiveStatus =
          existing.status === 'cancelling' && status === 'running' ? 'cancelling' : status
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
             -- 租约（P42）：running 时续期，终态清空；否则心跳一断就会被误回收
             lease_expires_at = case
                                  when $2 in ('done', 'failed', 'cancelled') then null
                                  else now() + make_interval(secs => $9::int)
                                end,
             started_at  = case when $2 = 'running' and started_at is null then now() else started_at end,
             finished_at = case when $2 in ('done', 'failed', 'cancelled') then now() else finished_at end
           where id = $1
           returning *`,
          [params.id, effectiveStatus, resultText, errorText, sessionId, pid, pidStartedAt, runner, leaseSec]
        )

        logger.info('command updated', { id: params.id, status: effectiveStatus })
        const [item] = await withAttachments([updated])
        sse.broadcast('command.update', toCommand(item))
        return { ok: true, command: toCommand(item) }
      }
    },

    {
      /**
       * bridge 续租（P42）。语义是「我还在负责这条命令」，所以：
       *   * 只续 delivered / running / cancelling，**不改状态、不推 SSE**
       *     —— 每 30 秒一条心跳都广播的话，手机上会被无意义的 command.update 刷屏；
       *   * 已经结束的命令返回 `finished: true`（迟到的心跳不该报错）；
       *   * 只认自己设备的命令，跨设备一律 403（与其它写接口一致）。
       */
      method: 'POST',
      pattern: '/api/v1/commands/:id/heartbeat',
      auth: 'device',
      async handler({ params, client }) {
        const existing = await db.one(
          'select id, device_id, status from commands where id = $1',
          [params.id]
        )
        if (!existing) throw new HttpError(404, 'command not found', 'not_found')
        if (existing.device_id !== client.id) {
          throw new HttpError(403, 'command belongs to another device', 'forbidden')
        }
        if (FINISHED.has(existing.status)) {
          return { ok: true, finished: true, status: existing.status }
        }

        const updated = await db.one(
          `update commands
             set lease_expires_at = now() + make_interval(secs => $2::int)
           where id = $1 and status in ('delivered', 'running', 'cancelling')
           returning lease_expires_at`,
          [params.id, leaseSec]
        )
        // 心跳与终态回写撞车时这里会拿不到行：结果是「已结束」，不是错误。
        return {
          ok: true,
          finished: !updated,
          leaseExpiresAt: updated?.lease_expires_at ?? null
        }
      }
    }
  ]
}
