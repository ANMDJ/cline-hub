import { HttpError } from '../http.js'
import {
  requireString,
  optionalString,
  intOrNull,
  isoOrNull,
  boolOrFalse,
  limitFrom,
  resolveDeviceId,
  toJsonArray,
  toJsonObject
} from '../util.js'

const UPSERT_SESSION = `
  insert into sessions (
    device_id, session_id, workspace, workspace_root, source, status, exit_code,
    provider, model, started_at, ended_at, updated_at, prompt, user_prompt,
    result_ok, result_error, result_text, result_truncated, commands, metrics, collected_at,
    project, project_root, project_kind
  ) values (
    $1, $2, $3, $4, $5, $6, $7,
    $8, $9, $10, $11, $12, $13, $14,
    $15, $16, $17, $18, $19::jsonb, $20::jsonb, coalesce($21::timestamptz, now()),
    $22, $23, $24
  )
  on conflict (device_id, session_id) do update set
    workspace        = excluded.workspace,
    workspace_root   = excluded.workspace_root,
    source           = excluded.source,
    status           = excluded.status,
    exit_code        = excluded.exit_code,
    provider         = excluded.provider,
    model            = excluded.model,
    started_at       = excluded.started_at,
    ended_at         = excluded.ended_at,
    updated_at       = excluded.updated_at,
    prompt           = excluded.prompt,
    user_prompt      = excluded.user_prompt,
    result_ok        = excluded.result_ok,
    result_error     = excluded.result_error,
    result_text      = excluded.result_text,
    result_truncated = excluded.result_truncated,
    commands         = excluded.commands,
    metrics          = excluded.metrics,
    collected_at     = excluded.collected_at,
    project          = excluded.project,
    project_root     = excluded.project_root,
    project_kind     = excluded.project_kind,
    updated_row_at   = now()
  returning (xmax = 0) as inserted
`

/**
 * 列表、游标、详情三处必须用同一个排序表达式，否则翻页会漏行。
 *
 * 进行中的会话 `ended_at` 是 null：这里刻意排成 `updated_at` 优先，
 * 让它跟着最新一条消息的时间走。若沿用 `started_at`，一个跑了半小时的
 * 会话会沉到列表下面，看起来像"没有最新记录"。
 */
const SORT_AT = 'coalesce(ended_at, updated_at, started_at)'

const LIST_COLUMNS = `
  device_id, session_id, workspace, workspace_root, source, status, exit_code,
  provider, model, started_at, ended_at, updated_at, prompt, user_prompt,
  project, project_root, project_kind,
  result_ok, result_error, result_truncated, metrics, collected_at,
  left(coalesce(result_text, ''), 400) as result_preview,
  jsonb_array_length(commands) as command_count,
  ${SORT_AT} as sort_at
`

function toListItem(row) {
  return {
    deviceId: row.device_id,
    sessionId: row.session_id,
    workspace: row.workspace,
    workspaceRoot: row.workspace_root,
    project: row.project,
    projectRoot: row.project_root,
    projectKind: row.project_kind,
    source: row.source,
    status: row.status,
    exitCode: row.exit_code,
    provider: row.provider,
    model: row.model,
    startedAt: row.started_at,
    endedAt: row.ended_at,
    updatedAt: row.updated_at,
    prompt: row.prompt,
    userPrompt: row.user_prompt,
    resultOk: row.result_ok,
    resultError: row.result_error,
    resultTruncated: row.result_truncated,
    resultPreview: row.result_preview,
    commandCount: row.command_count,
    metrics: row.metrics,
    collectedAt: row.collected_at,
    sortAt: row.sort_at
  }
}

export function toSessionDetail(row) {
  return { ...toListItem(row), resultText: row.result_text, commands: row.commands }
}

/**
 * Cursor paging: `<sort_at ISO>|<session_id>`. Sorting is descending, so the
 * cursor points at the last row the client already received.
 */
function parseCursor(raw) {
  if (!raw) return null
  const index = raw.lastIndexOf('|')
  if (index <= 0) return null
  const sortAt = isoOrNull(raw.slice(0, index))
  const sessionId = raw.slice(index + 1)
  if (!sortAt || !sessionId) return null
  return { sortAt, sessionId }
}

export { toListItem }

export function createSessionRoutes({ db, logger, sse }) {
  return [
    {
      method: 'POST',
      pattern: '/api/v1/sessions',
      auth: 'device',
      async handler({ body, client }) {
        const deviceId = resolveDeviceId(client, body)
        const session = body.session
        if (!session || typeof session !== 'object' || Array.isArray(session)) {
          throw new HttpError(400, 'session object is required', 'invalid_field')
        }

        const sessionId = requireString(session.sessionId, 'session.sessionId', { max: 200 })
        const commands = toJsonArray(session.commands)
        const metrics = toJsonObject(session.metrics)

        const result = await db.one(UPSERT_SESSION, [
          deviceId,
          sessionId,
          optionalString(session.workspace, 'session.workspace', 300),
          optionalString(session.workspaceRoot, 'session.workspaceRoot', 1000),
          optionalString(session.source, 'session.source', 50),
          optionalString(session.status, 'session.status', 50),
          intOrNull(session.exitCode),
          optionalString(session.provider, 'session.provider', 100),
          optionalString(session.model, 'session.model', 200),
          isoOrNull(session.startedAt),
          isoOrNull(session.endedAt),
          isoOrNull(session.updatedAt),
          optionalString(session.prompt, 'session.prompt', 8000),
          optionalString(session.userPrompt, 'session.userPrompt', 8000),
          boolOrFalse(session.resultOk),
          optionalString(session.resultError, 'session.resultError', 1000),
          optionalString(session.resultText, 'session.resultText', 20000),
          boolOrFalse(session.resultTruncated),
          JSON.stringify(commands),
          JSON.stringify(metrics),
          isoOrNull(session.collectedAt),
          optionalString(session.project, 'session.project', 200),
          optionalString(session.projectRoot, 'session.projectRoot', 1000),
          optionalString(session.projectKind, 'session.projectKind', 20)
        ])

        logger.info('session upserted', {
          deviceId,
          sessionId,
          status: session.status,
          inserted: result?.inserted === true,
          commands: commands.length
        })

        sse.broadcast('session', {
          deviceId,
          sessionId,
          status: session.status ?? null,
          workspace: session.workspace ?? null,
          endedAt: session.endedAt ?? null,
          resultPreview: String(session.resultText ?? '').slice(0, 200)
        })

        return { ok: true, sessionId, inserted: result?.inserted === true }
      }
    },

    {
      /**
       * bridge 的增量消息上报。
       *
       * 按 (device, session, message_id) upsert：流式回复的同一条消息会被重发覆盖，
       * 详情页不会出现重复气泡；一次最多 200 条，bridge 侧默认 40 条一批。
       */
      method: 'POST',
      pattern: '/api/v1/sessions/:sessionId/messages',
      auth: 'device',
      async handler({ params, body, client }) {
        const deviceId = resolveDeviceId(client, body)
        const sessionId = String(params.sessionId ?? '').trim()
        if (!sessionId) throw new HttpError(400, 'sessionId is required', 'invalid_field')

        const list = Array.isArray(body.messages) ? body.messages : []
        if (list.length === 0) return { ok: true, stored: 0 }
        if (list.length > 200) {
          throw new HttpError(400, 'at most 200 messages per call', 'invalid_field')
        }

        const values = []
        const tuples = []
        for (const item of list) {
          if (!item || typeof item !== 'object' || Array.isArray(item)) continue
          const messageId = String(item.id ?? '').trim()
          if (!messageId) continue
          const role = item.role === 'user' ? 'user' : 'assistant'
          const kind = item.kind === 'command' ? 'command' : 'text'
          const text = optionalString(item.text, 'messages[].text', 8000) ?? ''
          const tool = optionalString(item.tool, 'messages[].tool', 100)
          const base = values.length
          values.push(
            deviceId,
            sessionId,
            messageId,
            intOrNull(item.seq) ?? 0,
            role,
            kind,
            text,
            tool,
            isoOrNull(item.ts)
          )
          tuples.push(
            `($${base + 1}, $${base + 2}, $${base + 3}, $${base + 4}, $${base + 5}, ` +
            `$${base + 6}, $${base + 7}, $${base + 8}, $${base + 9}::timestamptz)`
          )
        }
        if (tuples.length === 0) return { ok: true, stored: 0 }

        await db.query(
          `insert into session_messages
             (device_id, session_id, message_id, seq, role, kind, text, tool, ts)
           values ${tuples.join(', ')}
           on conflict (device_id, session_id, message_id) do update set
             seq        = excluded.seq,
             role       = excluded.role,
             kind       = excluded.kind,
             text       = excluded.text,
             tool       = excluded.tool,
             ts         = excluded.ts,
             updated_at = now()`,
          values
        )

        logger.info('session messages stored', { deviceId, sessionId, stored: tuples.length })
        sse.broadcast('messages', { deviceId, sessionId, stored: tuples.length })
        return { ok: true, stored: tuples.length }
      }
    },

    {
      /** 详情页用：按 seq 升序，带 after 可做增量续拉。 */
      method: 'GET',
      pattern: '/api/v1/sessions/:sessionId/messages',
      auth: 'any',
      async handler({ params, url }) {
        // 不能写成 Number(searchParams.get('after') ?? '')：空串转数字是 0，
        // 会把 seq=0 的那条（用户原话）永久过滤掉。
        const afterRaw = url.searchParams.get('after')
        const after = afterRaw === null || afterRaw === '' ? null : Number(afterRaw)
        // before：向上翻历史（seq < before），返回顺序仍是正序
        const beforeRaw = url.searchParams.get('before')
        const before = beforeRaw === null || beforeRaw === '' ? null : Number(beforeRaw)
        const limit = limitFrom(url, 200, 2000)
        const values = [params.sessionId]
        const where = ['session_id = $1']

        if (after !== null && Number.isFinite(after)) {
          values.push(after)
          where.push(`seq > $${values.length}`)
        }
        if (before !== null && Number.isFinite(before)) {
          values.push(before)
          where.push(`seq < $${values.length}`)
        }
        const deviceId = optionalString(url.searchParams.get('deviceId'), 'deviceId', 100)
        if (deviceId) {
          values.push(deviceId)
          where.push(`device_id = $${values.length}`)
        }
        values.push(limit)

        // 不带 after 时按 desc 取「最近 N 条」再反转：否则大会话只拿到最旧的一段
        // （>800 条时最新消息反而不在里面）。after 是追新，必须升序。
        const asc = after !== null && Number.isFinite(after)
        const rows = await db.many(
          `select device_id, session_id, message_id, seq, role, kind, text, tool, ts
           from session_messages
           where ${where.join(' and ')}
           order by seq ${asc ? 'asc' : 'desc'}, created_at ${asc ? 'asc' : 'desc'}
           limit $${values.length}`,
          values
        )
        if (!asc) rows.reverse()

        return {
          ok: true,
          items: rows.map((row) => ({
            deviceId: row.device_id,
            sessionId: row.session_id,
            messageId: row.message_id,
            seq: row.seq,
            role: row.role,
            kind: row.kind,
            text: row.text,
            tool: row.tool,
            ts: row.ts
          })),
          hasMore: rows.length === limit
        }
      }
    },

    {
      method: 'GET',
      pattern: '/api/v1/sessions',
      auth: 'any',
      async handler({ url }) {
        const limit = limitFrom(url, 50, 200)
        const cursor = parseCursor(url.searchParams.get('cursor'))
        const workspace = optionalString(url.searchParams.get('workspace'), 'workspace', 300)
        const status = optionalString(url.searchParams.get('status'), 'status', 50)
        const deviceId = optionalString(url.searchParams.get('deviceId'), 'deviceId', 100)
        const search = optionalString(url.searchParams.get('q'), 'q', 200)
        const project = optionalString(url.searchParams.get('project'), 'project', 200)

        const where = []
        const values = []

        if (cursor) {
          values.push(cursor.sortAt, cursor.sessionId)
          const i = values.length
          where.push(`(${SORT_AT} < $${i - 1}
            or (${SORT_AT} = $${i - 1} and session_id < $${i}))`)
        }

        const equals = (column, value) => {
          if (!value) return
          values.push(value)
          where.push(`${column} = $${values.length}`)
        }
        equals('workspace', workspace)
        equals('project', project)
        equals('status', status)
        equals('device_id', deviceId)

        if (search) {
          values.push(`%${search}%`)
          const i = values.length
          where.push(`(result_text ilike $${i} or prompt ilike $${i} or user_prompt ilike $${i})`)
        }

        values.push(limit + 1)
        const sql = `
          select ${LIST_COLUMNS}
          from sessions
          ${where.length ? 'where ' + where.join(' and ') : ''}
          order by ${SORT_AT} desc nulls last, session_id desc
          limit $${values.length}
        `

        const rows = await db.many(sql, values)
        const hasMore = rows.length > limit
        const items = (hasMore ? rows.slice(0, limit) : rows).map(toListItem)
        const last = items.at(-1)

        return {
          ok: true,
          items,
          nextCursor: hasMore && last ? `${new Date(last.sortAt).toISOString()}|${last.sessionId}` : null
        }
      }
    },

    {
      method: 'GET',
      pattern: '/api/v1/sessions/:sessionId',
      auth: 'any',
      async handler({ params }) {
        const row = await db.one(
          `select *,
                  left(coalesce(result_text, ''), 400) as result_preview,
                  jsonb_array_length(commands) as command_count,
                  ${SORT_AT} as sort_at
           from sessions
           where session_id = $1
           order by updated_row_at desc
           limit 1`,
          [params.sessionId]
        )
        if (!row) throw new HttpError(404, 'session not found', 'not_found')
        return { ok: true, session: toSessionDetail(row) }
      }
    }
  ]
}


