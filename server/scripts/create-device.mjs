#!/usr/bin/env node
/**
 * Creates a client (device or app) and prints its token once.
 *
 *   npm run create-device -- --id localone --name LocalOne
 *   npm run create-device -- --id phone --role app --name "Pixel 8"
 *
 * Needs server/.env with HUB_DATABASE_URL. Alternatively POST /api/v1/clients
 * with the admin token — both paths write the same rows.
 */
import { config } from '../src/env.js'
import { createLogger } from '../src/logger.js'
import { createDb } from '../src/db.js'
import { hashToken, newToken } from '../src/auth.js'

function parseArgs(argv) {
  const out = {}
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i]
    if (!arg.startsWith('--')) continue
    const key = arg.slice(2)
    const next = argv[i + 1]
    if (next && !next.startsWith('--')) {
      out[key] = next
      i += 1
    } else {
      out[key] = 'true'
    }
  }
  return out
}

const args = parseArgs(process.argv.slice(2))
const id = String(args.id ?? '').trim().toLowerCase()
const role = String(args.role ?? 'device').trim()
const name = String(args.name ?? id).trim()

if (!/^[a-z0-9][a-z0-9._-]{1,31}$/.test(id)) {
  console.error('usage: npm run create-device -- --id <2-32 chars a-z0-9._-> [--role device|app] [--name "Display name"]')
  process.exit(1)
}
if (!['device', 'app'].includes(role)) {
  console.error('--role must be device or app')
  process.exit(1)
}

const logger = createLogger({ level: 'warn' })
const db = createDb({ databaseUrl: config.databaseUrl, logger })
const token = newToken()
const tokenHash = hashToken(token)

try {
  const row = await db.one(
    `insert into clients (id, name, role, token_hash)
     values ($1, $2, $3, $4)
     on conflict (id) do update set name = excluded.name, role = excluded.role, token_hash = excluded.token_hash
     returning id, name, role, created_at`,
    [id, name, role, tokenHash]
  )
  console.log('')
  console.log(`  client : ${row.id} (${row.role}) "${row.name}"`)
  console.log(`  token  : ${token}`)
  console.log('')
  console.log('  Bridge config.json -> "deviceId": "' + row.id + '", "deviceToken": "<token>"')
  console.log('  Phone app stores the same token in Settings.')
  console.log('')
} finally {
  await db.close()
}
