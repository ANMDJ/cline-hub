#!/usr/bin/env node
/**
 * 一次性重发某个会话的全部消息。
 *
 * 用途：`TRANSCRIPT_BACKFILL_LIMIT` 只回填最近 60 个会话，更早的会话仍是被旧上限
 * （2000 字）截断的历史版本。需要补全文时单独跑：
 *
 *   cd bridge && node scripts/resend-session.mjs 1791744249853_in12x
 *
 * 走的是和 bridge 正常上报完全相同的接口与鉴权，服务端按 message_id upsert，
 * 不会产生重复气泡。
 */
import fs from 'node:fs'
import path from 'node:path'
import { DatabaseSync } from 'node:sqlite'

import { loadConfig } from '../src/config.js'
import { extractTranscript } from '../src/extract.js'

const sessionId = process.argv[2]
if (!sessionId) {
  console.error('usage: node scripts/resend-session.mjs <sessionId>')
  process.exit(1)
}

const cfg = loadConfig()
if (!cfg.hubUrl || !cfg.deviceToken) {
  console.error('bridge/config.json 里缺 hubUrl 或 deviceToken')
  process.exit(1)
}

const dbPath = path.join(cfg.dataDir, 'db', 'sessions.db')
const db = new DatabaseSync(dbPath, { readOnly: true })
const row = db.prepare('select messages_path from sessions where session_id = ?').get(sessionId)
if (!row?.messages_path) {
  console.error(`sessions.db 里找不到 ${sessionId}（或没有 messages_path）`)
  process.exit(1)
}
if (!fs.existsSync(row.messages_path)) {
  console.error(`messages.json 不存在：${row.messages_path}`)
  process.exit(1)
}

const result = extractTranscript(row.messages_path, cfg)
if (!result.ok) {
  console.error(`抽取失败：${result.reason}`)
  process.exit(1)
}

const batchSize = Number(cfg.messageBatch) > 0 ? Number(cfg.messageBatch) : 40
const batchBytes = 64 * 1024
const batches = []
let chunk = []
let bytes = 0
const flush = () => {
  if (chunk.length === 0) return
  batches.push(chunk)
  chunk = []
  bytes = 0
}
for (const message of result.messages) {
  const size = Buffer.byteLength(JSON.stringify(message))
  if (chunk.length > 0 && (chunk.length >= batchSize || bytes + size > batchBytes)) flush()
  chunk.push(message)
  bytes += size
}
flush()

const endpoint = `${cfg.hubUrl}/api/v1/sessions/${encodeURIComponent(sessionId)}/messages`
let stored = 0
for (const [index, batch] of batches.entries()) {
  const response = await fetch(endpoint, {
    method: 'POST',
    headers: {
      'content-type': 'application/json; charset=utf-8',
      authorization: `Bearer ${cfg.deviceToken}`
    },
    body: JSON.stringify({ sessionId, messages: batch }),
    signal: AbortSignal.timeout(20000)
  })
  if (!response.ok) {
    console.error(`第 ${index + 1}/${batches.length} 批失败：HTTP ${response.status} ${await response.text()}`)
    process.exit(1)
  }
  stored += batch.length
  process.stdout.write(`\r已重发 ${stored}/${result.messages.length} 条`)
}
process.stdout.write('\n')
console.log(`完成：${sessionId}，${stored} 条消息，${batches.length} 批`)
