import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'

import { createCommandWorker } from '../src/command-worker.js'

const silentLogger = { info() {}, warn() {}, error() {} }

async function waitFor(check, timeoutMs = 8000, stepMs = 50) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (check()) return true
    await new Promise((resolve) => setTimeout(resolve, stepMs))
  }
  return false
}

/**
 * 假 cline：只有收到 `--json` 才吐 NDJSON；否则吐纯文本。
 * 用真实 CLI 跑端到端太慢、要额度，这里只验证 bridge 侧「加参数 → 解析 → 回写」。
 */
const FAKE_CLINE = `
import fs from 'node:fs'
const argv = process.argv.slice(2)
if (process.env.FAKE_CLINE_ARGV_FILE) {
  fs.writeFileSync(process.env.FAKE_CLINE_ARGV_FILE, JSON.stringify(argv))
}
const json = argv.includes('--json')
const fail = process.env.FAKE_CLINE_FAIL === '1'
const lines = []
if (json) {
  lines.push({ ts: new Date().toISOString(), type: 'hook_event', hookEventName: 'agent_start', agentId: 'agent_test', taskId: 'conv_test' })
  if (fail) {
    lines.push({ type: 'agent_event', event: { type: 'error', error: { message: 'Authentication Fails (governor)' }, errorClass: 'auth', recoverable: false } })
  } else {
    lines.push({ type: 'agent_event', event: { type: 'done', reason: 'completed', text: 'OK', iterations: 1, usage: { inputTokens: 12, outputTokens: 1, totalCost: 0.0002 } } })
    lines.push({ type: 'run_result', finishReason: 'completed', text: 'OK', usage: { inputTokens: 12, outputTokens: 1, totalCost: 0.0002 }, model: { id: 'fake-model', provider: 'fake' } })
  }
}
for (const line of lines) process.stdout.write(JSON.stringify(line) + '\\n')
if (!json) process.stdout.write('RAW-OUTPUT\\n')
process.exit(0)
`

function makeCfg(hubUrl, workspace, clineEntry, clineExtra = {}) {
  return {
    hubUrl,
    deviceId: 'testdevice',
    deviceToken: 'testtoken',
    workspaceWhitelist: [workspace],
    dataDir: path.join(workspace, 'data'),
    commands: {
      enabled: true,
      runner: 'cline',
      allowModes: ['plan', 'act'],
      defaultWorkspace: workspace,
      timeoutMs: 60000,
      batchSize: 1,
      cline: { jsEntry: clineEntry, provider: 'fake', model: 'fake-model', ...clineExtra }
    }
  }
}

/** 起一个假 Hub、跑一条命令，返回 PATCH 记录与假 cline 收到的 argv。 */
async function runScenario({ commandId, fail = false, clineExtra = {}, extraArgs = [] }) {
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'cline-hub-json-'))
  const entry = path.join(workspace, 'fake-cline.mjs')
  fs.writeFileSync(entry, FAKE_CLINE, 'utf8')
  const argvFile = path.join(workspace, 'argv.json')

  const patches = []
  let claimed = false
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1')
    let raw = ''
    req.on('data', (chunk) => { raw += chunk })
    req.on('end', () => {
      if (req.method === 'GET' && url.pathname === '/api/v1/commands/pending') {
        const items = claimed
          ? []
          : [{
              id: commandId,
              prompt: 'Say OK now',
              mode: 'act',
              workspace,
              createdAt: new Date().toISOString()
            }]
        claimed = true
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ items }))
        return
      }
      if (req.method === 'GET' && url.pathname === '/api/v1/commands') {
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end('{"items":[]}')
        return
      }
      if (req.method === 'PATCH' && url.pathname.startsWith('/api/v1/commands/')) {
        patches.push({ at: Date.now(), ...JSON.parse(raw || '{}') })
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end('{"ok":true}')
        return
      }
      res.writeHead(404, { 'content-type': 'application/json' })
      res.end('{}')
    })
  })
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  const hubUrl = `http://127.0.0.1:${server.address().port}`

  const previousArgvFile = process.env.FAKE_CLINE_ARGV_FILE
  const previousFail = process.env.FAKE_CLINE_FAIL
  process.env.FAKE_CLINE_ARGV_FILE = argvFile
  process.env.FAKE_CLINE_FAIL = fail ? '1' : '0'
  const worker = createCommandWorker({
    cfg: makeCfg(hubUrl, workspace, entry, clineExtra),
    logger: silentLogger
  })

  try {
    await worker.tick()
    const finished = await waitFor(() => patches.some((item) => item.status === 'done' || item.status === 'failed'))
    assert.ok(finished, '命令应该在 8 秒内回写终态')
    const argv = JSON.parse(fs.readFileSync(argvFile, 'utf8'))
    return { patches, argv }
  } finally {
    await worker.shutdown({ reason: 'test over', reportTimeoutMs: 1000 })
    await new Promise((resolve) => server.close(resolve))
    if (previousArgvFile === undefined) delete process.env.FAKE_CLINE_ARGV_FILE
    else process.env.FAKE_CLINE_ARGV_FILE = previousArgvFile
    if (previousFail === undefined) delete process.env.FAKE_CLINE_FAIL
    else process.env.FAKE_CLINE_FAIL = previousFail
  }
}

test('cline 默认带 --json：done 的 resultText 是干净终稿，不是 JSON 原文', async () => {
  const { patches, argv } = await runScenario({ commandId: 'cmd_json_ok' })
  assert.ok(argv.includes('--json'), '应该给 cline 传 --json')
  const done = patches.find((item) => item.status === 'done')
  assert.ok(done, '应该回写 done')
  assert.equal(done.resultText, 'OK')
  assert.equal(done.errorText, undefined)
})

test('--json 事件里的 error 让命令判 failed（即使 exit code 是 0）', async () => {
  const { patches } = await runScenario({ commandId: 'cmd_json_fail', fail: true })
  const failed = patches.find((item) => item.status === 'failed')
  assert.ok(failed, '认证失败应该回写 failed')
  assert.match(failed.errorText, /Authentication Fails/)
})

test('commands.cline.json=false 时不传 --json，退回原始输出', async () => {
  const { patches, argv } = await runScenario({
    commandId: 'cmd_json_off',
    clineExtra: { json: false }
  })
  assert.equal(argv.includes('--json'), false)
  const done = patches.find((item) => item.status === 'done')
  assert.ok(done)
  assert.equal(done.resultText.trim(), 'RAW-OUTPUT')
})

