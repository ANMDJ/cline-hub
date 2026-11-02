import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'

import { createCommandWorker } from '../src/command-worker.js'

/**
 * P7：命令并发池。
 *
 * 两个断言是这块的全部价值：
 *   1. `commands.concurrency=2` 时，两条**不同 workspace** 的命令真的同时在跑；
 *   2. 同一个 workspace 的两条命令永远串行（第二条的 running 必须晚于第一条的终态）。
 *
 * 用 `runner: 'shell'` + PowerShell `Start-Sleep` 制造可控时长，不碰 cline / 不烧额度。
 */

const silentLogger = { info() {}, warn() {}, error() {} }

async function waitFor(check, timeoutMs = 15000, stepMs = 40) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (check()) return true
    await new Promise((resolve) => setTimeout(resolve, stepMs))
  }
  return false
}

function makeCfg(hubUrl, workspaces, concurrency) {
  return {
    hubUrl,
    deviceId: 'testdevice',
    deviceToken: 'testtoken',
    workspaceWhitelist: workspaces,
    dataDir: path.join(workspaces[0], 'data'),
    commands: {
      enabled: true,
      runner: 'shell',
      template: '{prompt}',
      shell: 'powershell',
      allowModes: ['plan', 'act'],
      defaultWorkspace: workspaces[0],
      timeoutMs: 60000,
      /** 两个并发槽位；batchSize 一次领完，验证「领一批、池里并行」。 */
      concurrency,
      batchSize: 2,
      cline: {}
    }
  }
}

/** 起假 Hub：一次性吐出 commands，记录所有 PATCH（带时间戳）。 */
async function startHub(commands) {
  const patches = []
  let claimed = false
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1')
    let raw = ''
    req.on('data', (chunk) => { raw += chunk })
    req.on('end', () => {
      if (req.method === 'GET' && url.pathname === '/api/v1/commands/pending') {
        const items = claimed ? [] : commands
        claimed = true
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ items }))
        return
      }
      if (req.method === 'GET' && url.pathname === '/api/v1/commands') {
        // reconcile 的查询：没有 running / cancelling 的命令。
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end('{"items":[]}')
        return
      }
      if (req.method === 'GET' && url.pathname.startsWith('/api/v1/commands/')) {
        // 取消预检：都当作「还在排队」，不拦。
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end('{"command":{"status":"delivered"}}')
        return
      }
      if (req.method === 'PATCH' && url.pathname.startsWith('/api/v1/commands/')) {
        patches.push({ at: Date.now(), id: url.pathname.split('/').pop(), ...JSON.parse(raw || '{}') })
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end('{"ok":true}')
        return
      }
      res.writeHead(404, { 'content-type': 'application/json' })
      res.end('{}')
    })
  })
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  return { server, patches, url: `http://127.0.0.1:${server.address().port}` }
}

function command(id, workspace, script) {
  return {
    id,
    prompt: script,
    mode: 'act',
    workspace,
    createdAt: new Date().toISOString()
  }
}

test('concurrency=2：不同 workspace 的两条命令同时在跑', {
  skip: process.platform !== 'win32' ? '只在 Windows 上跑（PowerShell）' : false,
  timeout: 60000
}, async () => {
  const a = fs.mkdtempSync(path.join(os.tmpdir(), 'cline-hub-pool-a-'))
  const b = fs.mkdtempSync(path.join(os.tmpdir(), 'cline-hub-pool-b-'))
  const { server, patches, url } = await startHub([
    command('cmd_pool_a', a, 'Start-Sleep -Milliseconds 1500'),
    command('cmd_pool_b', b, 'Start-Sleep -Milliseconds 1500')
  ])

  const worker = createCommandWorker({
    cfg: makeCfg(url, [a, b], 2),
    logger: silentLogger
  })

  try {
    await worker.tick()

    const bothRunning = await waitFor(
      () => new Set(patches.filter((item) => item.status === 'running').map((item) => item.id)).size === 2,
      5000
    )
    assert.ok(bothRunning, `两条命令应该同时进入 running，实际：${JSON.stringify(patches)}`)
    assert.equal(
      patches.filter((item) => item.status === 'done' || item.status === 'failed').length,
      0,
      '两条都还在跑的时候不应该已经有终态'
    )

    const finished = await waitFor(
      () => patches.filter((item) => item.status === 'done').length === 2,
      15000
    )
    assert.ok(finished, `两条命令都应该 done，实际：${JSON.stringify(patches)}`)
  } finally {
    await worker.shutdown({ reason: 'test over', reportTimeoutMs: 500 })
    await new Promise((resolve) => server.close(resolve))
    for (const dir of [a, b]) fs.rmSync(dir, { recursive: true, force: true })
  }
})

test('同一个 workspace 强制串行：第二条 running 晚于第一条终态', {
  skip: process.platform !== 'win32' ? '只在 Windows 上跑（PowerShell）' : false,
  timeout: 60000
}, async () => {
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'cline-hub-pool-serial-'))
  const { server, patches, url } = await startHub([
    command('cmd_serial_1', workspace, 'Start-Sleep -Milliseconds 800'),
    command('cmd_serial_2', workspace, 'Start-Sleep -Milliseconds 800')
  ])

  const worker = createCommandWorker({
    cfg: makeCfg(url, [workspace], 2),
    logger: silentLogger
  })

  try {
    await worker.tick()

    const done = await waitFor(
      () => patches.filter((item) => item.status === 'done').length === 2,
      20000
    )
    assert.ok(done, `两条命令都应该跑完，实际：${JSON.stringify(patches)}`)

    const firstDoneAt = patches.find((item) => item.id === 'cmd_serial_1' && item.status === 'done').at
    const secondRunningAt = patches.find((item) => item.id === 'cmd_serial_2' && item.status === 'running').at
    assert.ok(
      secondRunningAt >= firstDoneAt,
      `同 workspace 不能并行：第二条 running ${secondRunningAt} 应晚于第一条 done ${firstDoneAt}`
    )
  } finally {
    await worker.shutdown({ reason: 'test over', reportTimeoutMs: 500 })
    await new Promise((resolve) => server.close(resolve))
    fs.rmSync(workspace, { recursive: true, force: true })
  }
})
