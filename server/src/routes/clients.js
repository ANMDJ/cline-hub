import { HttpError } from '../http.js'
import { newToken, hashToken } from '../auth.js'
import { requireString, optionalString } from '../util.js'

const ID_PATTERN = /^[a-z0-9][a-z0-9._-]{1,31}$/
const ROLES = new Set(['device', 'app'])

function toClient(row) {
  return {
    id: row.id,
    name: row.name,
    role: row.role,
    createdAt: row.created_at,
    lastSeenAt: row.last_seen_at,
    sessionCount: row.session_count,
    pendingCommands: row.pending_commands
  }
}

/**
 * 设备列表的对外形状（`GET /api/v1/devices`）。
 *
 * 只给「电脑端」(`role='device'`)：手机自己的 app client 不算设备，
 * 否则设备筛选里会出现用户根本没在下发目标里见过的 id。
 */
function toDevice(row) {
  return {
    id: row.id,
    name: row.name,
    createdAt: row.created_at,
    lastSeenAt: row.last_seen_at,
    sessionCount: row.session_count,
    commandCount: row.command_count,
    pendingCommands: row.pending_commands,
    runningCommands: row.running_commands,
    lastSessionAt: row.last_session_at,
    lastCommandAt: row.last_command_at
  }
}

export function createClientRoutes({ db, logger }) {
  return [
    {
      // App 也要能读，所以是 `any` 而不是 `admin`：device token 只看自己，
      // app/admin 看全部电脑端（ADR-47）。`GET /api/v1/clients` 仍是 admin 专属。
      method: 'GET',
      pattern: '/api/v1/devices',
      auth: 'any',
      async handler({ client }) {
        if (!client) throw new HttpError(401, 'missing or invalid token', 'unauthorized')

        const scoped = client.role === 'device'
        const rows = await db.many(
          `select c.id, c.name, c.created_at, c.last_seen_at,
                  (select count(*)::int from sessions s where s.device_id = c.id) as session_count,
                  (select count(*)::int from commands m where m.device_id = c.id) as command_count,
                  (select count(*)::int from commands m
                    where m.device_id = c.id and m.status in ('pending', 'delivered')) as pending_commands,
                  (select count(*)::int from commands m
                    where m.device_id = c.id and m.status in ('running', 'cancelling')) as running_commands,
                  (select max(coalesce(s.ended_at, s.started_at, s.updated_at, s.collected_at))
                     from sessions s where s.device_id = c.id) as last_session_at,
                  (select max(m.created_at) from commands m where m.device_id = c.id) as last_command_at
           from clients c
           where c.role = 'device'${scoped ? ' and c.id = $1' : ''}
           order by c.created_at asc`,
          scoped ? [client.id] : []
        )
        return { ok: true, items: rows.map(toDevice) }
      }
    },

    {
      method: 'GET',
      pattern: '/api/v1/clients',
      auth: 'admin',
      async handler() {
        const rows = await db.many(
          `select c.id, c.name, c.role, c.created_at, c.last_seen_at,
                  (select count(*)::int from sessions s where s.device_id = c.id) as session_count,
                  (select count(*)::int from commands m
                    where m.device_id = c.id and m.status in ('pending', 'delivered')) as pending_commands
           from clients c
           order by c.created_at asc`
        )
        return { ok: true, items: rows.map(toClient) }
      }
    },

    {
      method: 'POST',
      pattern: '/api/v1/clients',
      auth: 'admin',
      status: 201,
      async handler({ body }) {
        const id = requireString(body.id, 'id', { max: 32 }).toLowerCase()
        if (!ID_PATTERN.test(id)) {
          throw new HttpError(
            400,
            'id must be 2-32 chars of a-z 0-9 . _ - and start with a letter or digit',
            'invalid_field'
          )
        }
        const role = optionalString(body.role, 'role', 10) ?? 'device'
        if (!ROLES.has(role)) {
          throw new HttpError(400, `role must be one of ${[...ROLES].join(', ')}`, 'invalid_field')
        }
        const name = optionalString(body.name, 'name', 100) ?? id
        const token = newToken()

        try {
          const row = await db.one(
            `insert into clients (id, name, role, token_hash)
             values ($1, $2, $3, $4)
             returning id, name, role, created_at, last_seen_at`,
            [id, name, role, hashToken(token)]
          )
          logger.info('client created', { id, role })
          // the raw token is only ever returned here; only its hash is stored
          return { ok: true, client: toClient(row), token }
        } catch (error) {
          if (error.code === '23505') {
            throw new HttpError(409, `client ${id} already exists`, 'already_exists')
          }
          throw error
        }
      }
    },

    {
      method: 'DELETE',
      pattern: '/api/v1/clients/:id',
      auth: 'admin',
      async handler({ params, url }) {
        if (url.searchParams.get('confirm') !== '1') {
          throw new HttpError(400, 'add ?confirm=1 to delete a client', 'confirm_required')
        }
        const row = await db.one('delete from clients where id = $1 returning id', [params.id])
        if (!row) throw new HttpError(404, 'client not found', 'not_found')
        logger.warn('client deleted', { id: row.id })
        return { ok: true, id: row.id }
      }
    }
  ]
}
