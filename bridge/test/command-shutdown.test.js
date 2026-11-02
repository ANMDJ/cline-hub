import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'

import { createCommandWorker, interruptionErrorText } from '../src/command-worker.js'
import { inspectProcesses } from '../src/process-info.js'

const silentLogger = { info() {}, warn() {}, error() {} }

async function waitFor(check, timeoutMs = 8000, stepMs = 50) {
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
      batchSize: 1,
      cline: {}
    }
  }
}

test('interruptionErrorText 写清原因，并说明可以重新下发', () => {
  const text = interruptionErrorText('升级 bridge')
  assert.match(text, /bridge 正在关闭（升级 bridge）/)
  assert.match(text, /直接重新下发/)
  assert.match(text, /不是命令执行失败/)
})

test('interruptionErrorText 没给原因时也要能看懂', () => {
  const text = interruptionErrorText('')
  assert.match(text, /未说明原因/)
  assert.match(text, /bridge 正在关闭/)
})

test('interruptionErrorText 去掉原因两端空白', () => {
  assert.ok(interruptionErrorText('  重启  ').includes('（重启）'))
})

/**
 * 端到端（本机）验证「先回写、再杀、再退出」的顺序。
 *
 * 一个假 Hub 替身负责发一条命令（PowerShell 睡 30 秒），然后立刻 shutdown：
 * 断言 shutdown 返回时 `failed` 已经发出（说明发生在杀进程之前），
 * 并且 handle() 收尾时不会再补一条 `exit code -1` 把原因覆盖掉。
 */
test('shutdown 先回写 failed 再杀进程，handle() 不再覆盖原因', {
  skip: process.platform !== 'win32' ? '只在 Windows 上跑（taskkill / PowerShell）' : false,
  timeout: 60000
}, async () => {
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'cline-hub-shutdown-'))
  const commandId = 'cmd_shutdown_case'
  const entryFile = path.join(os.tmpdir(), 'cline-hub-cmd', 'running', `${commandId}.json`)
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
              prompt: 'Start-Sleep -Seconds 30',
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

  const worker = createCommandWorker({ cfg: makeCfg(hubUrl, workspace), logger: silentLogger })
  try {
    const ticking = worker.tick()
    const spawned = await waitFor(() => patches.some((item) => item.status === 'running' && item.pid))
    assert.ok(spawned, '命令应该在 8 秒内 spawn 并回写 pid')

    const result = await worker.shutdown({ reason: '测试优雅退出' })

    // 关键断言：shutdown 返回时 failed 已经发出 —— 即「先回写状态，再杀进程」。
    const failed = patches.filter((item) => item.status === 'failed')
    assert.deepEqual(result.interrupted, [commandId])
    assert.equal(failed.length, 1, `应只有一条 failed，实际：${JSON.stringify(patches)}`)
    assert.match(failed[0].errorText, /bridge 正在关闭（测试优雅退出）/)

    await ticking
    await new Promise((resolve) => setTimeout(resolve, 400))
    assert.equal(
      patches.filter((item) => item.status === 'failed').length,
      1,
      'handle() 不应再补一条 exit code 失败把原因覆盖掉'
    )
  } finally {
    worker.stop()
    await new Promise((resolve) => server.close(resolve))
    try {
      fs.unlinkSync(entryFile)
    } catch {}
    fs.rmSync(workspace, { recursive: true, force: true })
  }
})

/**
 * `npm run restart -- --keep-session` 的依据：`keepChildren: true` 时只回写 failed，
 * **不杀**子进程。否则「在手机上下发重启 bridge」会把发起这条命令的会话一起掐死，
 * 脚本自己也活不到「拉起新 bridge」那一步。
 */
test('shutdown({ keepChildren: true }) 回写 failed 但保留子进程', {
  skip: process.platform !== 'win32' ? '只在 Windows 上跑（taskkill / PowerShell）' : false,
  timeout: 60000
}, async () => {
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'cline-hub-keep-'))
  const commandId = 'cmd_keep_case'
  const entryFile = path.join(os.tmpdir(), 'cline-hub-cmd', 'running', `${commandId}.json`)
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
              prompt: 'Start-Sleep -Seconds 30',
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

  const worker = createCommandWorker({ cfg: makeCfg(hubUrl, workspace), logger: silentLogger })
  let ticking = null
  let pid = null
  try {
    ticking = worker.tick()
    const spawned = await waitFor(() => patches.some((item) => item.status === 'running' && item.pid))
    assert.ok(spawned, '命令应该在 8 秒内 spawn 并回写 pid')
    pid = Number(patches.find((item) => item.status === 'running' && item.pid).pid)

    const result = await worker.shutdown({ reason: '测试保留会话', keepChildren: true })

    assert.deepEqual(result.interrupted, [commandId])
    assert.equal(result.keptChildren, true)
    assert.equal(
      patches.filter((item) => item.status === 'failed').length,
      1,
      '状态还是要回写：手机不能停在「执行中」'
    )

    await new Promise((resolve) => setTimeout(resolve, 300))
    assert.ok(inspectProcesses([pid]).has(pid), `keepChildren 时子进程 ${pid} 必须还在`)
  } finally {
    // 先杀再等这条命令收尾：keepChildren 下 handle() 一直等到子进程退出。
    // tick() 现在是「领了就返回」，所以要显式等 pid 消失，不能只 await ticking。
    worker.stop()
    if (ticking) await ticking.catch(() => {})
    if (pid) await waitFor(() => !inspectProcesses([pid]).has(pid), 8000)
    await new Promise((resolve) => server.close(resolve))
    try {
      fs.unlinkSync(entryFile)
    } catch {}
    // Windows 上子进程的 cwd 句柄释放有延迟，删目录要重试几次。
    for (let attempt = 0; attempt < 5; attempt += 1) {
      try {
        fs.rmSync(workspace, { recursive: true, force: true })
        break
      } catch {
        await new Promise((resolve) => setTimeout(resolve, 200))
      }
    }
  }
})
