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
    result_ok, result_error, result_text, result_truncated, commands, metrics, collected_at
  ) values (
    $1, $2, $3, $4, $5, $6, $7,
    $8, $9, $10, $11, $12, $13, $14,
    $15, $16, $17, $18, $19::jsonb, $20::jsonb, coalesce($21::timestamptz, now())
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
    updated_row_at   = now()
  returning (xmax = 0) as inserted
`

const LIST_COLUMNS = `
  device_id, session_id, workspace, workspace_root, source, status, exit_code,
  provider, model, started_at, ended_at, updated_at, prompt, user_prompt,
  result_ok, result_error, result_truncated, metrics, collected_at,
  left(coalesce(result_text, ''), 400) as result_preview,
  jsonb_array_length(commands) as command_count,
  coalesce(ended_at, started_at, updated_at) as sort_at
`

function toListItem(row) {
  return {
    deviceId: row.device_id,
    sessionId: row.session_id,
    workspace: row.workspace,
    workspaceRoot: row.workspace_root,
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
          isoOrNull(session.collectedAt)
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

        const where = []
        const values = []

        if (cursor) {
          values.push(cursor.sortAt, cursor.sessionId)
          const i = values.length
          where.push(`(coalesce(ended_at, started_at, updated_at) < $${i - 1}
            or (coalesce(ended_at, started_at, updated_at) = $${i - 1} and session_id < $${i}))`)
        }

        const equals = (column, value) => {
          if (!value) return
          values.push(value)
          where.push(`${column} = $${values.length}`)
        }
        equals('workspace', workspace)
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
          order by coalesce(ended_at, started_at, updated_at) desc nulls last, session_id desc
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
                  coalesce(ended_at, started_at, updated_at) as sort_at
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


