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

export function createClientRoutes({ db, logger }) {
  return [
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
