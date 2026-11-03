import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'

import { createCommandWorker } from '../src/command-worker.js'

/**
 * P42：bridge 的租约心跳。
 *
 * 这条链路只有一个关键断言：**命令在跑的时候，bridge 会周期性叫
 * `POST /api/v1/commands/:id/heartbeat`**，否则 Hub 会把命令判成失联。
 * 附带的第二个断言是「空闲时一个心跳都不发」——心跳不该变成无意义的轮询。
 *
 * 用 `runner: 'shell'` + PowerShell `Start-Sleep` 控制时长，不碰 cline / 不烧额度。
 */

const silentLogger = { info() {}, warn() {}, error() {} }

function makeCfg(hubUrl, workspace) {
  return {
    hubUrl,
    deviceId: 'testdevice',
    deviceToken: 'testtoken',
    workspaceWhitelist: [workspace],
    dataDir: path.join(workspace, 'data'),
    commands: {
      enabled: true,
      runner: 'shell',
      template: '{prompt}',
      shell: 'powershell',
      allowModes: ['plan', 'act'],
      defaultWorkspace: workspace,
      timeoutMs: 60000,
      concurrency: 1,
      batchSize: 1,
      // 测试里把「30 秒」压到 150ms，否则一条两秒的命令永远等不到第二次心跳
      leaseHeartbeatMs: 150,
      cline: {}
    }
  }
}

/** 假 Hub：pending 一次吐完，记录 heartbeat 与 PATCH。 */
async function startHub(commands) {
  const heartbeats = []
  const patches = []
  let claimed = false
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1')
    let raw = ''
    req.on('data', (chunk) => {
      raw += chunk
    })
    req.on('end', () => {
      if (req.method === 'GET' && url.pathname === '/api/v1/commands/pending') {
        const items = claimed ? [] : commands
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
      if (req.method === 'POST' && url.pathname.endsWith('/heartbeat')) {
        heartbeats.push({
          at: Date.now(),
          id: decodeURIComponent(url.pathname.split('/').at(-2))
        })
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end('{"ok":true,"finished":false}')
        return
      }
      if (req.method === 'GET' && url.pathname.startsWith('/api/v1/commands/')) {
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end('{"command":{"status":"delivered"}}')
        return
      }
      if (req.method === 'PATCH' && url.pathname.startsWith('/api/v1/commands/')) {
        patches.push({ id: url.pathname.split('/').pop(), ...JSON.parse(raw || '{}') })
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end('{"ok":true}')
        return
      }
      res.writeHead(404, { 'content-type': 'application/json' })
      res.end('{}')
    })
  })
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  return { server, heartbeats, patches, url: `http://127.0.0.1:${server.address().port}` }
}

test('命令在跑时定期续租，空闲时一个心跳都不发', {
  skip: process.platform !== 'win32' ? '只在 Windows 上跑（PowerShell）' : false,
  timeout: 60000
}, async () => {
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'cline-hub-lease-'))
  const command = {
    id: 'cmd_lease_1',
    prompt: 'Start-Sleep -Milliseconds 1200',
    mode: 'act',
    workspace,
    createdAt: new Date().toISOString()
  }
  const { server, heartbeats, patches, url } = await startHub([command])

  const worker = createCommandWorker({ cfg: makeCfg(url, workspace), logger: silentLogger })

  try {
    // 真实运行时由 index.js 每 5 秒 tick 一次；测试里手动驱动，
    // 不然一条 1.2 秒的命令在「只 tick 一次」的情况下根本走不到心跳。
    const deadline = Date.now() + 20000
    while (Date.now() < deadline && !patches.some((item) => item.status === 'done')) {
      await worker.tick()
      await new Promise((resolve) => setTimeout(resolve, 100))
    }
    const done = patches.some((item) => item.status === 'done')
    assert.ok(done, `命令应该跑完，实际 PATCH：${JSON.stringify(patches)}`)

    assert.ok(
      heartbeats.length >= 1,
      `命令在跑的时候应该续租，实际：${JSON.stringify(heartbeats)}`
    )
    assert.deepEqual(
      [...new Set(heartbeats.map((item) => item.id))],
      ['cmd_lease_1'],
      '只该给本机负责的命令续租'
    )
  } finally {
    await worker.shutdown({ reason: 'test over', reportTimeoutMs: 500 })
    await new Promise((resolve) => server.close(resolve))
    fs.rmSync(workspace, { recursive: true, force: true })
  }
})

test('没有活命令时不会发心跳（空闲零请求）', {
  timeout: 20000
}, async () => {
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'cline-hub-lease-idle-'))
  const { server, heartbeats, url } = await startHub([])
  const worker = createCommandWorker({ cfg: makeCfg(url, workspace), logger: silentLogger })

  try {
    for (let i = 0; i < 5; i += 1) {
      await worker.tick()
      await new Promise((resolve) => setTimeout(resolve, 100))
    }
    assert.equal(heartbeats.length, 0, `空闲时不该发心跳：${JSON.stringify(heartbeats)}`)
  } finally {
    await worker.shutdown({ reason: 'test over', reportTimeoutMs: 500 })
    await new Promise((resolve) => server.close(resolve))
    fs.rmSync(workspace, { recursive: true, force: true })
  }
})
