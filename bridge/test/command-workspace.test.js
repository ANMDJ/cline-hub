import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'

import { createCommandWorker } from '../src/command-worker.js'

/**
 * 执行前的「工作目录不可用」必须报清楚原因（ADR-61）。
 *
 * 真实事故：`cmd_e48d2ee78e0e` 带了 `...\chat\pcother`，但本机没有这个目录，
 * bridge 回写的是「这条命令没带 workspace」——文案指向了错误的排查方向。
 * 这里固定三条：带了但不存在 / 带了但是个文件 / 压根没带，各说各的。
 *
 * 前三条都不会 spawn 进程，所以不需要 PowerShell；第四条验证「默认目录兜底」仍然有效。
 */

const silentLogger = { info() {}, warn() {}, error() {} }

async function waitFor(check, timeoutMs = 10000, stepMs = 50) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const value = check()
    if (value) return value
    await new Promise((resolve) => setTimeout(resolve, stepMs))
  }
  return null
}

function makeCfg(hubUrl, defaultWorkspace = '') {
  return {
    hubUrl,
    deviceId: 'testdevice',
    deviceToken: 'testtoken',
    workspaceWhitelist: [],
    dataDir: path.join(os.tmpdir(), 'cline-hub-workspace-data'),
    commands: {
      enabled: true,
      runner: 'shell',
      template: '{prompt}',
      shell: 'powershell',
      allowModes: ['plan', 'act'],
      defaultWorkspace,
      timeoutMs: 60000,
      concurrency: 1,
      batchSize: 1,
      cline: {}
    }
  }
}

/** 假 Hub：pending 一次性吐完，记录所有 PATCH。 */
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
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end('{"items":[]}')
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
  return { server, patches, url: `http://127.0.0.1:${server.address().port}` }
}

function command(id, workspace, prompt = 'Write-Output ok') {
  return { id, prompt, mode: 'plan', workspace, createdAt: new Date().toISOString() }
}

/** 跑一轮 tick，等到第一条终态回写，然后收起 worker / 假 Hub。 */
async function runOnce(workspace, cfgOptions = {}) {
  const { server, patches, url } = await startHub([
    command('cmd_ws_1', workspace, cfgOptions.prompt)
  ])
  const worker = createCommandWorker({
    cfg: makeCfg(url, cfgOptions.defaultWorkspace),
    logger: silentLogger
  })
  try {
    await worker.tick()
    const terminal = await waitFor(() =>
      patches.find((item) => item.status === 'done' || item.status === 'failed')
    )
    assert.ok(terminal, `命令应该有终态，实际：${JSON.stringify(patches)}`)
    return terminal
  } finally {
    await worker.shutdown({ reason: 'test over', reportTimeoutMs: 500 })
    await new Promise((resolve) => server.close(resolve))
  }
}

test('workspace 带了但本机不存在：文案要带上这个路径，而不是说「没带 workspace」', {
  timeout: 20000
}, async () => {
  const missing = path.join(os.tmpdir(), `cline-hub-missing-${process.pid}-${Date.now()}`, 'pcother')
  assert.equal(fs.existsSync(missing), false, '测试前提：这个目录不该存在')

  const terminal = await runOnce(missing)
  assert.equal(terminal.status, 'failed')
  assert.ok(
    terminal.errorText.includes(`workspace "${missing}"`),
    `文案应指出是哪个目录不可用：${terminal.errorText}`
  )
  assert.ok(
    terminal.errorText.includes('在本机不存在'),
    `文案应说明不存在：${terminal.errorText}`
  )
  assert.equal(
    terminal.errorText.includes('没带 workspace'),
    false,
    `带了 workspace 时不该再说「没带」：${terminal.errorText}`
  )
  assert.ok(
    terminal.errorText.includes('commands.defaultWorkspace 未配置'),
    `没配兜底时也要说清楚：${terminal.errorText}`
  )
  // P49：执行前拒绝要能被手机识别出来（不是「跑完才失败」）。
  assert.equal(terminal.rejectedBeforeStart, true, JSON.stringify(terminal))
  assert.equal(terminal.rejectedReason, 'workspace_missing', JSON.stringify(terminal))
})

test('workspace 指向一个文件：文案要说「不是目录」', {
  timeout: 20000
}, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cline-hub-ws-file-'))
  const file = path.join(dir, 'notes.txt')
  fs.writeFileSync(file, 'not a workspace', 'utf8')

  try {
    const terminal = await runOnce(file)
    assert.equal(terminal.status, 'failed')
    assert.ok(terminal.errorText.includes(`workspace "${file}"`), terminal.errorText)
    assert.ok(terminal.errorText.includes('不是目录'), terminal.errorText)
    assert.equal(terminal.rejectedBeforeStart, true, JSON.stringify(terminal))
    assert.equal(terminal.rejectedReason, 'workspace_missing', JSON.stringify(terminal))
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test('没带 workspace 且未配默认目录：文案指向 defaultWorkspace', {
  timeout: 20000
}, async () => {
  const terminal = await runOnce('')
  assert.equal(terminal.status, 'failed')
  assert.ok(terminal.errorText.includes('这条命令没带 workspace'), terminal.errorText)
  assert.ok(terminal.errorText.includes('commands.defaultWorkspace 未配置'), terminal.errorText)
  assert.equal(terminal.rejectedBeforeStart, true, JSON.stringify(terminal))
  assert.equal(terminal.rejectedReason, 'workspace_missing', JSON.stringify(terminal))
})

test('workspace 不可用但配了有效的默认目录：仍然回落到默认目录执行', {
  skip: process.platform !== 'win32' ? '只在 Windows 上跑（PowerShell）' : false,
  timeout: 30000
}, async () => {
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'cline-hub-ws-default-'))
  const missing = path.join(workspace, 'pcother')
  try {
    const terminal = await runOnce(missing, { defaultWorkspace: workspace })
    assert.equal(terminal.status, 'done', JSON.stringify(terminal))
    // 兜底成功 = 真的跑了，不能带「未执行」标记。
    assert.equal(terminal.rejectedBeforeStart ?? false, false, JSON.stringify(terminal))
  } finally {
    fs.rmSync(workspace, { recursive: true, force: true })
  }
})
