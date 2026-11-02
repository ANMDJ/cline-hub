import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'

import { createCommandWorker } from '../src/command-worker.js'
import { inspectProcesses } from '../src/process-info.js'

/**
 * P14：手机端取消。
 *
 *   1. 执行中取消 → bridge 按 commandId 杀掉进程树，回写 `cancelled`（不是 failed）；
 *   2. 排队中取消 → 预检看到 Hub 上已是 `cancelled`，直接不 spawn（不产生任何 running）。
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
      batchSize: 2,
      cline: {}
    }
  }
}

async function startHub({ commands, cancelledIds = new Set() }) {
  const patches = []
  const state = { claimed: false, cancelling: false }
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1')
    let raw = ''
    req.on('data', (chunk) => { raw += chunk })
    req.on('end', () => {
      const json = (body) => {
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify(body))
      }
      if (req.method === 'GET' && url.pathname === '/api/v1/commands/pending') {
        const items = state.claimed ? [] : commands
        state.claimed = true
        return json({ items })
      }
      if (req.method === 'GET' && url.pathname === '/api/v1/commands') {
        const status = url.searchParams.get('status')
        if (status === 'cancelling' && state.cancelling) {
          return json({ items: commands.map((item) => ({ ...item, status: 'cancelling' })) })
        }
        return json({ items: [] })
      }
      if (req.method === 'GET' && url.pathname.startsWith('/api/v1/commands/')) {
        const id = url.pathname.split('/').pop()
        return json({ command: { id, status: cancelledIds.has(id) ? 'cancelled' : 'delivered' } })
      }
      if (req.method === 'PATCH' && url.pathname.startsWith('/api/v1/commands/')) {
        patches.push({ id: url.pathname.split('/').pop(), ...JSON.parse(raw || '{}') })
        return json({ ok: true })
      }
      res.writeHead(404, { 'content-type': 'application/json' })
      res.end('{}')
    })
  })
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  return { server, patches, state, url: `http://127.0.0.1:${server.address().port}` }
}

function cleanupWorkspace(workspace) {
  return (async () => {
    for (let attempt = 0; attempt < 5; attempt += 1) {
      try {
        fs.rmSync(workspace, { recursive: true, force: true })
        return
      } catch {
        await new Promise((resolve) => setTimeout(resolve, 200))
      }
    }
  })()
}

test('执行中取消：杀掉进程树并回写 cancelled', {
  skip: process.platform !== 'win32' ? '只在 Windows 上跑（PowerShell / taskkill）' : false,
  timeout: 60000
}, async () => {
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'cline-hub-cancel-run-'))
  const { server, patches, state, url } = await startHub({
    commands: [{
      id: 'cmd_cancel_running',
      prompt: 'Start-Sleep -Seconds 60',
      mode: 'act',
      workspace,
      createdAt: new Date().toISOString()
    }]
  })

  const worker = createCommandWorker({ cfg: makeCfg(url, workspace), logger: silentLogger })

  try {
    await worker.tick()
    const running = await waitFor(() => patches.find((item) => item.status === 'running' && item.pid))
    assert.ok(running, `命令应该先进入 running，实际：${JSON.stringify(patches)}`)
    const pid = Number(patches.find((item) => item.status === 'running' && item.pid).pid)

    // 手机点了取消：Hub 上这条命令变成 cancelling。
    state.cancelling = true
    await worker.tick() // tick 里顺带做取消轮询

    const cancelledAt = await waitFor(
      () => patches.find((item) => item.status === 'cancelled'),
      12000
    )
    const cancelled = patches.find((item) => item.status === 'cancelled')
    assert.ok(cancelledAt && cancelled, `应该回写 cancelled，实际：${JSON.stringify(patches)}`)
    assert.match(
      String(cancelled.errorText),
      /已取消/,
      `cancelled 的 errorText 应该说明原因，实际：${JSON.stringify(patches)}`
    )
    assert.equal(patches.filter((item) => item.status === 'failed').length, 0, '取消不是失败')
    assert.ok(
      await waitFor(() => !inspectProcesses([pid]).has(pid), 8000),
      `进程 ${pid} 应该被结束`
    )
  } finally {
    await worker.shutdown({ reason: 'test over', reportTimeoutMs: 500 })
    await new Promise((resolve) => server.close(resolve))
    await cleanupWorkspace(workspace)
  }
})

test('排队中取消：预检发现已取消，不 spawn、不写 running', {
  skip: process.platform !== 'win32' ? '只在 Windows 上跑（PowerShell）' : false,
  timeout: 60000
}, async () => {
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'cline-hub-cancel-queued-'))
  const { server, patches, url } = await startHub({
    commands: [
      {
        id: 'cmd_cancel_first',
        prompt: 'Start-Sleep -Milliseconds 400',
        mode: 'act',
        workspace,
        createdAt: new Date().toISOString()
      },
      {
        id: 'cmd_cancel_queued',
        prompt: 'Start-Sleep -Seconds 30',
        mode: 'act',
        workspace,
        createdAt: new Date().toISOString()
      }
    ],
    cancelledIds: new Set(['cmd_cancel_queued'])
  })

  const worker = createCommandWorker({ cfg: makeCfg(url, workspace), logger: silentLogger })

  try {
    await worker.tick()

    const firstDone = await waitFor(
      () => patches.find((item) => item.id === 'cmd_cancel_first' && item.status === 'done'),
      15000
    )
    assert.ok(firstDone, `第一条应该正常跑完，实际：${JSON.stringify(patches)}`)

    // 第二条被取消：根本没有 running，也没有 done/failed。
    await new Promise((resolve) => setTimeout(resolve, 800))
    assert.equal(
      patches.filter((item) => item.id === 'cmd_cancel_queued').length,
      0,
      `被取消的排队命令不应该被执行，实际：${JSON.stringify(patches)}`
    )
  } finally {
    await worker.shutdown({ reason: 'test over', reportTimeoutMs: 500 })
    await new Promise((resolve) => server.close(resolve))
    await cleanupWorkspace(workspace)
  }
})
