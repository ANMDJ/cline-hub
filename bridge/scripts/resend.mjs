#!/usr/bin/env node
/**
 * 手工重发：把「会话快照 + 消息流」按正常上报的字段重推一遍。
 *
 * 什么时候用：
 *   * 项目识别（ADR-22）/ 路径归一化（ADR-44）上线后，老会话的 `project*` 还是空，
 *     列表里只能退化成按绝对路径分组 —— 重发一次就补上了。
 *   * 采集规则升级（`TRANSCRIPT_VERSION`）漏掉的静止会话。
 *   * 换了 Hub / 换设备 token 想补历史（用 `--device` + `--token`）。
 *
 * 为什么不是「删 state.json 再重启 bridge」：重启会掐断执行中的命令（ADR-36），
 * 而且会把最近 100 条全推一遍。这里只推你点名的那几条，不碰 bridge 进程。
 *
 * 用法：
 *   cd bridge
 *   npm run resend -- --missing-project --dry-run     # 先看要补哪些
 *   npm run resend -- --missing-project               # 按 Hub 上 project 为空的会话补
 *   npm run resend -- --session 1791744249853_in12x   # 指定一条（可重复 / 逗号分隔）
 *   npm run resend -- --recent 20                     # 最近 20 条
 *
 * 参数：
 *   --session <id>     重发这条会话（可多次给，也可逗号分隔）
 *   --missing-project  从 Hub 拉列表，挑 `project` / `projectKind` 都为空的旧会话
 *   --recent <n>       最近 n 条（按 updated_at 倒序）
 *   --limit <n>        --missing-project 时从 Hub 拉多少条（默认 200，服务端上限 200）
 *   --no-messages      只补会话快照（project* / 终稿 / 用量），不重发消息
 *   --dry-run          只打印，不发请求
 *   --device <id>      以哪台设备身份上报（默认 config.deviceId）
 *   --token <token>    配套 --device 用（默认 config.deviceToken）
 *   --data-dir <dir>   读哪台机器的 Cline 数据（默认 config.dataDir）
 *
 * 服务端按 sessionId / message_id upsert，重复跑不会产生重复气泡。
 */
import fs from 'node:fs'
import path from 'node:path'
import { parseArgs } from 'node:util'

import { loadConfig } from '../src/config.js'
import { openSessionsDb, getSessionById, listRecentSessions } from '../src/db.js'
import { extractSession, extractTranscript } from '../src/extract.js'
import { toRecord } from '../src/record.js'

const USAGE = `用法：
  node scripts/resend.mjs --missing-project [--dry-run]
  node scripts/resend.mjs --session <sessionId> [--session <id2>]
  node scripts/resend.mjs --recent <n>

参数见脚本头部注释。`

const { values } = parseArgs({
  allowPositionals: true,
  options: {
    session: { type: 'string', multiple: true, default: [] },
    'missing-project': { type: 'boolean', default: false },
    recent: { type: 'string' },
    limit: { type: 'string', default: '200' },
    'no-messages': { type: 'boolean', default: false },
    'dry-run': { type: 'boolean', default: false },
    device: { type: 'string' },
    token: { type: 'string' },
    'data-dir': { type: 'string' },
    help: { type: 'boolean', default: false }
  }
})

if (values.help) {
  console.log(USAGE)
  process.exit(0)
}

const cfg = loadConfig()
const hubUrl = cfg.hubUrl
const deviceId = String(values.device || cfg.deviceId || '').trim()
const token = String(values.token || cfg.deviceToken || '').trim()
const dataDir = values['data-dir'] ? path.resolve(values['data-dir']) : cfg.dataDir
const dryRun = values['dry-run']
const withMessages = !values['no-messages']

if (!hubUrl || !deviceId || !token) {
  console.error('缺 hubUrl / deviceId / deviceToken：检查 bridge/config.json，或用 --device / --token 指定')
  process.exit(1)
}

const explicitIds = values.session
  .flatMap((value) => String(value).split(','))
  .map((value) => value.trim())
  .filter(Boolean)

if (explicitIds.length === 0 && !values['missing-project'] && !values.recent) {
  console.error(USAGE)
  process.exit(1)
}

const limit = Math.min(Math.max(Number(values.limit) || 200, 1), 200)

let db
try {
  db = openSessionsDb(dataDir)
} catch (error) {
  console.error(`打不开 sessions.db：${error.message}`)
  process.exit(1)
}

const headers = {
  'content-type': 'application/json; charset=utf-8',
  authorization: `Bearer ${token}`
}

async function request(method, url, body) {
  const response = await fetch(url, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(30000)
  })
  if (!response.ok) {
    const text = await response.text()
    throw new Error(`${method} ${url} -> HTTP ${response.status} ${text}`)
  }
  return response.json().catch(() => ({}))
}

/** Hub 上 `project*` 三列为空的旧会话：只能从服务端读，本地算出来的永远是新值。
 *
 * 判据是「`project` 和 `projectKind` 都为空」，不是只看 `project`：
 * 散会话（`projectKind=loose`）的 project 本来就是空，重发也不会变；
 * 真正要补的是项目识别（ADR-22）上线前写进来的那批，三列全空。
 */
async function missingProjectIds() {
  const url = `${hubUrl}/api/v1/sessions?limit=${limit}&deviceId=${encodeURIComponent(deviceId)}`
  const json = await request('GET', url)
  const items = Array.isArray(json.items) ? json.items : []
  const missing = items.filter(
    (item) =>
      !String(item.project ?? '').trim() && !String(item.projectKind ?? '').trim()
  )
  if (items.length >= limit) {
    console.log(`提示：Hub 返回了 ${items.length} 条（已到 limit），更早的会话不在本次范围内`)
  }
  return missing.map((item) => String(item.sessionId ?? '')).filter(Boolean)
}

/** 和 bridge 正常上报完全一致的批次划分（条数 + 字节数上限）。 */
function batchMessages(messages, batchSize) {
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
  for (const message of messages) {
    const size = Buffer.byteLength(JSON.stringify(message))
    if (chunk.length > 0 && (chunk.length >= batchSize || bytes + size > batchBytes)) flush()
    chunk.push(message)
    bytes += size
  }
  flush()
  return batches
}

async function resendOne(sessionId, index, total) {
  const prefix = `[${index + 1}/${total}] ${sessionId}`
  const row = getSessionById(db, sessionId)
  if (!row) {
    console.warn(`${prefix} 跳过：本地 sessions.db 里没有（可能不在这台机器上）`)
    return { skipped: true }
  }

  const extraction = extractSession(row.messages_path, cfg)
  const record = toRecord(row, extraction)
  const label = `${record.project || record.projectKind}/${record.workspace || '(无目录)'}`

  if (dryRun) {
    console.log(`${prefix} 待重发：${label}，status=${record.status}，消息${withMessages ? '' : '（跳过）'}`)
    return { sent: 0, batches: 0 }
  }

  await request('POST', `${hubUrl}/api/v1/sessions`, { deviceId, session: record })

  let sent = 0
  let batches = 0
  if (withMessages && row.messages_path && fs.existsSync(row.messages_path)) {
    const transcript = extractTranscript(row.messages_path, cfg)
    if (!transcript.ok) {
      console.warn(`${prefix} 消息抽取失败（${transcript.reason ?? 'unknown'}），只补了会话快照`)
    } else {
      const batchSize = Number(cfg.messageBatch) > 0 ? Number(cfg.messageBatch) : 40
      const all = batchMessages(transcript.messages, batchSize)
      batches = all.length
      for (const batch of all) {
        await request(
          'POST',
          `${hubUrl}/api/v1/sessions/${encodeURIComponent(sessionId)}/messages`,
          { deviceId, sessionId, messages: batch }
        )
        sent += batch.length
        process.stdout.write(`\r${prefix} 已重发 ${sent}/${transcript.messages.length} 条`)
      }
      process.stdout.write('\r')
    }
  }

  console.log(`${prefix} 完成：${label}，消息 ${sent} 条 / ${batches} 批`)
  return { sent, batches }
}

const targets = []
if (explicitIds.length > 0) {
  targets.push(...explicitIds)
} else if (values['missing-project']) {
  const ids = await missingProjectIds()
  if (ids.length === 0) {
    console.log('Hub 上没有 project 为空的会话，无需重发')
    db.close()
    process.exit(0)
  }
  console.log(`Hub 上有 ${ids.length} 条 project 为空的会话`)
  targets.push(...ids)
} else if (values.recent) {
  const count = Math.min(Math.max(Number(values.recent) || 10, 1), 500)
  targets.push(...listRecentSessions(db, count).map((row) => row.session_id))
}

const unique = [...new Set(targets)]
console.log(`设备 ${deviceId} · ${dryRun ? '试运行' : '开始重发'} · ${unique.length} 条会话 · 数据 ${dataDir}`)

let failures = 0
let done = 0
for (const [index, sessionId] of unique.entries()) {
  try {
    const result = await resendOne(sessionId, index, unique.length)
    if (!result.skipped) done += 1
  } catch (error) {
    failures += 1
    console.error(`[${index + 1}/${unique.length}] ${sessionId} 失败：${error.message}`)
  }
}

db.close()
console.log(`结束：${done} 条成功，${failures} 条失败`)
process.exit(failures > 0 ? 1 : 0)
