import fs from 'node:fs'
import path from 'node:path'

import { config, serverRoot } from './env.js'
import { createLogger } from './logger.js'
import { createDb } from './db.js'

const MIGRATIONS_DIR = path.join(serverRoot, 'migrations')

/**
 * Applies every *.sql in migrations/ in filename order, once, each in its own
 * transaction. Filenames are the ordering key (001_, 002_, ...).
 */
export async function runMigrations(db, logger) {
  await db.query(`
    create table if not exists schema_migrations (
      name       text primary key,
      applied_at timestamptz not null default now()
    )
  `)

  const applied = new Set((await db.many('select name from schema_migrations')).map((row) => row.name))
  const files = fs
    .readdirSync(MIGRATIONS_DIR)
    .filter((file) => file.endsWith('.sql'))
    .sort()

  let count = 0
  for (const file of files) {
    if (applied.has(file)) continue
    const sql = fs.readFileSync(path.join(MIGRATIONS_DIR, file), 'utf8')
    await db.tx(async (client) => {
      await client.query(sql)
      await client.query('insert into schema_migrations (name) values ($1)', [file])
    })
    logger.info('migration applied', { file })
    count += 1
  }

  if (count === 0) logger.info('migrations up to date', { total: files.length })
  return count
}

// `npm run migrate` entry point
if (process.argv[1] && process.argv[1].endsWith('migrate.js')) {
  const logger = createLogger({ level: config.logLevel })
  const db = createDb({ databaseUrl: config.databaseUrl, logger })
  try {
    await runMigrations(db, logger)
    logger.info('migrate done')
    process.exitCode = 0
  } catch (error) {
    logger.error('migrate failed', { message: error.message, code: error.code })
    process.exitCode = 1
  } finally {
    await db.close()
  }
}
