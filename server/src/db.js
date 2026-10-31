import pg from 'pg'

const { Pool } = pg

/**
 * Thin wrapper around pg: everything goes through here so the handlers never
 * touch the pool directly (easier to swap for a different driver later).
 */
export function createDb({ databaseUrl, logger }) {
  if (!databaseUrl) {
    throw new Error('HUB_DATABASE_URL is empty: copy server/.env.example to server/.env')
  }

  const pool = new Pool({
    connectionString: databaseUrl,
    max: 10,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 5_000
  })

  pool.on('error', (error) => {
    logger.error('pg pool error', { message: error.message })
  })

  return {
    pool,
    query: (text, params) => pool.query(text, params),
    async one(text, params) {
      const result = await pool.query(text, params)
      return result.rows[0] ?? null
    },
    async many(text, params) {
      const result = await pool.query(text, params)
      return result.rows
    },
    async tx(fn) {
      const client = await pool.connect()
      try {
        await client.query('BEGIN')
        const out = await fn(client)
        await client.query('COMMIT')
        return out
      } catch (error) {
        await client.query('ROLLBACK').catch(() => {})
        throw error
      } finally {
        client.release()
      }
    },
    async ping() {
      const startedAt = Date.now()
      await pool.query('select 1')
      return Date.now() - startedAt
    },
    close: () => pool.end()
  }
}
