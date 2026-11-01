#!/usr/bin/env node
/**
 * Rotates a client token in place (keeps client id, history and role).
 *
 *   node scripts/rotate-token.mjs --id phone --out ../.secrets/phone-token.txt
 *   node scripts/rotate-token.mjs --id localone            # prints token once
 *
 * Only the sha256 hash is stored, so a lost token cannot be recovered — rotate instead.
 * Prefer `--out` on machines where command output might be logged or screen-shared.
 */
import { writeFileSync } from 'node:fs'
import { config } from '../src/env.js'
import { createDb } from '../src/db.js'
import { hashToken, newToken } from '../src/auth.js'

const args = {}
for (let i = 2; i < process.argv.length; i += 1) {
  const arg = process.argv[i]
  if (!arg.startsWith('--')) continue
  const next = process.argv[i + 1]
  if (next && !next.startsWith('--')) {
    args[arg.slice(2)] = next
    i += 1
  } else {
    args[arg.slice(2)] = 'true'
  }
}

const id = String(args.id ?? '').trim().toLowerCase()
if (!id) {
  console.error('usage: node scripts/rotate-token.mjs --id <client-id> [--out <file>]')
  process.exit(1)
}

const db = createDb({ databaseUrl: config.databaseUrl, logger: console })
const token = newToken()

try {
  const updated = await db.query('update clients set token_hash = $1 where id = $2', [hashToken(token), id])
  if (!updated.rowCount) {
    console.error(`no client with id=${id}`)
    process.exit(1)
  }
} finally {
  await db.close()
}

if (args.out && args.out !== 'true') {
  writeFileSync(args.out, `${token}\n`, { mode: 0o600 })
  console.log(`rotated id=${id} → ${args.out}（只显示这一次，文件已按 600 写入）`)
} else {
  console.log(`rotated id=${id}`)
  console.log(token)
  console.log('（只显示这一次；丢了就再 rotate 一次）')
}
