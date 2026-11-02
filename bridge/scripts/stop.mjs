import fs from 'node:fs'
import path from 'node:path'
import { spawn, spawnSync } from 'node:child_process'

import { bridgeRoot } from '../src/config.js'
import { interruptionErrorText } from '../src/command-worker.js'
import { readEntries, registryDir } from '../src/command-registry.js'

/**
 * 优雅停止 / 重启 bridge。
 *
 * 为什么需要它（2026-11-02）：Windows 上 `Stop-Process` / `taskkill` 都是直接
 * TerminateProcess，Node 收不到 SIGTERM，index.js 的 shutdown() 不会执行 ——
 * 正在跑的命令既没被回写 failed，也没被优雅收尾，手机上的卡片就卡在
 * 「执行中」，直到下一次启动对账。
 *
 * 用法：
 *   npm run stop -- --reason "升级 bridge"
 *   npm run restart -- --reason "升级 bridge"
 *   npm run stop -- --timeout 30000      # 放宽等待时间
 *   npm run restart -- --when-idle --reason "升级 bridge"  # 等执行中的命令跑完再重启（P18）
 *   npm run restart -- --keep-session --reason "在手机命令里重启"  # ⚠ 保不住会话，见下
 *
 * 流程：POST /admin/stop（本机回环）→ bridge 回写执行中的命令 → 杀进程树 → 退出。
 * 每次主动中断都请在 docs/interruptions.md 追加一条记录。
 *
 * `--keep-session`（2026-11-02）：bridge 拉起的命令**就是**发起这次重启的那个会话时用。
 * 否则 `/t` 会把 cline 子进程和这个脚本一起杀掉（脚本本身也在同一棵进程树里）。
 * 带这个开关时：bridge 照常回写 failed + 存 state，但**不杀**子进程。
 *
 * ⚠ 实测结论（同日 12:24，见 docs/interruptions.md）：这**保不住会话**。bridge 一退出，
 * 子进程的 stdout/stderr 管道（`stdio: ['ignore','pipe','pipe']`）就断了，cline 会在
 * 十几秒后自己 exit 1。要「重启但不掐断当前命令」，等 P18 的
 * `npm run restart -- --when-idle`（detached supervisor 等命令跑完再重启）。
 * 这条开关只适合「进程还要继续跑、结果不再需要 bridge 收」的极少数场景。
 */

const args = process.argv.slice(2)
const restart = args.includes('--restart')
/** 不杀 bridge 的子进程（正在跑的命令）；见文件头说明。 */
const keepSession = args.includes('--keep-session')
/** 不在这里停：交给 detached supervisor 等命令跑完再停/重启（P18）。 */
const whenIdle = args.includes('--when-idle')

function flag(name, fallback = '') {
  const index = args.indexOf(name)
  return index >= 0 ? args[index + 1] : fallback
}

const reason = String(flag('--reason', 'manual stop')).trim() || 'manual stop'
const timeoutMs = Number(flag('--timeout', 20000)) || 20000
/** 只有用户显式给了 --timeout 才传给 supervisor；否则让它用自己的 2 小时默认值。 */
const explicitTimeout = args.includes('--timeout')
/** `--when-idle` 空闲后的缓冲，避免刚好有新命令被领取时重启。 */
const graceMs = Number(flag('--grace', 3000)) || 3000
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

function readHookTarget() {
  const fallback = { host: '127.0.0.1', port: 3210 }
  try {
    const raw = JSON.parse(fs.readFileSync(path.join(bridgeRoot, 'config.json'), 'utf8'))
    const port = Number(raw.hookPort)
    return {
      host: String(raw.hookHost ?? fallback.host),
      port: Number.isInteger(port) && port > 0 && port < 65536 ? port : fallback.port
    }
  } catch {
    return fallback
  }
}

const { host, port } = readHookTarget()
const localHost = host === '0.0.0.0' || host === '::' ? '127.0.0.1' : host
const base = `http://${localHost}:${port}`

/**
 * `--when-idle`：这里不做任何停止动作，只排一个 detached supervisor。
 * 它轮询 `%TEMP%\cline-hub-cmd\running\`，等没有活着的命令后再调用本脚本
 * （带 `--restart` 就重启，否则只停）。这样在命令里发起的重启不会掐断当前会话。
 */
if (whenIdle) {
  const supervisor = path.join(bridgeRoot, 'scripts', 'restart-when-idle.mjs')
  const supervisorArgs = [supervisor, '--reason', reason, '--grace', String(graceMs)]
  if (explicitTimeout) supervisorArgs.push('--timeout', String(timeoutMs))
  if (!restart) supervisorArgs.push('--stop-only')
  const child = spawn(process.execPath, supervisorArgs, {
    cwd: bridgeRoot,
    detached: true,
    stdio: 'ignore',
    windowsHide: true,
    env: process.env
  })
  child.unref()
  console.log(`→ 已排队：等执行中的命令跑完后${restart ? '重启' : '停止'} bridge（supervisor pid ${child.pid ?? '?'}）`)
  console.log(`  日志：${path.join(bridgeRoot, 'logs', 'restart-when-idle.log')}`)
  console.log('  当前命令可以继续跑；它结束后 supervisor 才会动手。')
  process.exit(0)
}

async function alive() {
  try {
    const response = await fetch(`${base}/health`, { signal: AbortSignal.timeout(1500) })
    return response.ok
  } catch {
    return false
  }
}

/** 读 /health：确认这个端口上跑的确实是 cline-bridge，别把别人的 404 当信号。 */
async function readHealth() {
  try {
    const response = await fetch(`${base}/health`, { signal: AbortSignal.timeout(1500) })
    if (!response.ok) return null
    return await response.json().catch(() => ({}))
  } catch {
    return null
  }
}

async function waitFor(want, ms) {
  const deadline = Date.now() + ms
  while (Date.now() < deadline) {
    if ((await alive()) === want) return true
    await sleep(300)
  }
  return (await alive()) === want
}

function startBridge() {
  const child = spawn(process.execPath, ['src/index.js'], {
    cwd: bridgeRoot,
    detached: true,
    stdio: 'ignore',
    windowsHide: true,
    env: process.env
  })
  child.unref()
  return child.pid ?? null
}

function readRawConfig() {
  try {
    return JSON.parse(fs.readFileSync(path.join(bridgeRoot, 'config.json'), 'utf8'))
  } catch {
    return {}
  }
}

/**
 * 旧版本 bridge（没有 `/admin/stop`）的兜底：脚本自己先回写 in-flight 命令，再交给硬杀。
 *
 * 顺序仍然是「先恢复状态、再杀进程」：登记文件里有 commandId / pid，
 * Hub 地址和 token 从 `config.json` 读。回写失败不阻塞，留给下次启动的对账。
 */
async function reportInFlightInterrupted(why) {
  const entries = readEntries(registryDir())
  if (entries.length === 0) {
    console.log('  · 本机登记里没有执行中的命令，无需回写')
    return 0
  }
  const raw = readRawConfig()
  const hubUrl = String(raw.hubUrl ?? '').trim().replace(/\/+$/, '')
  const token = String(raw.deviceToken ?? '').trim()
  if (!hubUrl) {
    console.log('  · config.json 没有 hubUrl，跳过回写（下次 bridge 启动对账会收尾）')
    return 0
  }
  const errorText = interruptionErrorText(why)
  let patched = 0
  for (const entry of entries) {
    try {
      const response = await fetch(
        `${hubUrl}/api/v1/commands/${encodeURIComponent(entry.commandId)}`,
        {
          method: 'PATCH',
          headers: {
            'content-type': 'application/json; charset=utf-8',
            ...(token ? { authorization: `Bearer ${token}` } : {})
          },
          body: JSON.stringify({ status: 'failed', errorText }),
          signal: AbortSignal.timeout(3000)
        }
      )
      if (response.ok) {
        patched++
        console.log(`  · ${entry.commandId} → failed（bridge 正在关闭）`)
      } else {
        console.log(`  · ${entry.commandId} 回写失败：HTTP ${response.status}`)
      }
    } catch (error) {
      console.log(`  · ${entry.commandId} 回写失败：${error.message}`)
    }
  }
  return patched
}

/**
 * 找不到 `/admin/stop` 时的硬杀：只匹配命令行里带 `src/index.js` 的 node.exe，
 * 再按 pid 杀进程树。跑这个脚本的 node 进程不会命中（命令行是 scripts/stop.mjs）。
 */
function killBridgeProcesses() {
  const script = [
    '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8',
    "$rows = Get-CimInstance Win32_Process -Filter \"Name='node.exe'\" |",
    "  Where-Object { $_.CommandLine -like '*src/index.js*' } |",
    '  ForEach-Object { [pscustomobject]@{ pid = [int]$_.ProcessId } }',
    '[pscustomobject]@{ items = @($rows) } | ConvertTo-Json -Compress -Depth 3'
  ].join('\n')
  const result = spawnSync(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script],
    { encoding: 'utf8', windowsHide: true, timeout: 15000 }
  )
  let pids = []
  try {
    const parsed = JSON.parse(result.stdout || '{}')
    const items = Array.isArray(parsed?.items) ? parsed.items : parsed?.items ? [parsed.items] : []
    pids = items
      .map((item) => Number(item.pid))
      .filter((pid) => Number.isInteger(pid) && pid > 0 && pid !== process.pid)
  } catch {}
  if (pids.length === 0) {
    console.log('  · 没找到 bridge 进程（可能已经退出）')
    return []
  }
  for (const pid of pids) {
    // 默认带 /t：连 bridge 拉起的 cline 子进程一起收掉（正常关机语义）。
    // `--keep-session` 只杀 bridge 本身：子进程是正在跑的命令，杀掉等于把发起重启的
    // 那次对话截断；而且这个脚本自己也在同一棵树里，/t 会把它一并带走，重启跑不完。
    const flags = keepSession
      ? ['/pid', String(pid), '/f']
      : ['/pid', String(pid), '/t', '/f']
    spawnSync('taskkill', flags, { windowsHide: true, encoding: 'utf8' })
  }
  return pids
}

const info = await readHealth()
if (info) {
  if (!String(info.service ?? '').includes('cline-bridge')) {
    console.error(`✗ ${base} 上有服务在应答，但不是 cline-bridge（service=${info.service ?? '?'}），不动它`)
    process.exit(1)
  }

  console.log(`→ 请求优雅退出（${base}）：${reason}`)
  let response
  try {
    response = await fetch(`${base}/admin/stop`, {
      method: 'POST',
      headers: { 'content-type': 'application/json; charset=utf-8' },
      body: JSON.stringify(keepSession ? { reason, keepChildren: true } : { reason }),
      signal: AbortSignal.timeout(5000)
    })
  } catch (error) {
    console.error(`✗ 连不上 ${base}/admin/stop：${error.message}`)
    console.error('  急停单条命令：npm run ps；bridge 本身请重新启动后走 npm run stop')
    process.exit(1)
  }

  if (response.status === 404) {
    // 旧版本 bridge 没有这个入口：脚本侧先回写状态，再硬杀（顺序仍然是「先状态、后进程」）。
    console.log('⚠ 当前 bridge 是旧版本（没有 /admin/stop）：改为「先回写状态 → 再硬杀」')
    const patched = await reportInFlightInterrupted(reason)
    const pids = killBridgeProcesses()
    console.log(`✓ 已结束 bridge 进程：${pids.join(', ') || '(无)'}；回写 ${patched} 条执行中的命令`)
    if (keepSession) console.log('  · --keep-session：只杀了 bridge，子进程未被 taskkill（但管道已断，会话可能仍会结束）')
  } else if (!response.ok) {
    console.error(`✗ ${response.status} ${(await response.text()).slice(0, 200)}`)
    process.exit(1)
  } else {
    const body = await response.json().catch(() => ({}))
    console.log(`✓ 已请求退出（reason=${body.reason ?? reason}）`)
    if (body.keepChildren === true) {
      console.log('  执行中的命令会先回写 failed，但子进程保留（--keep-session；注意 bridge 退出后管道断开，会话仍可能结束）…')
    } else {
      console.log('  执行中的命令会先回写 failed（原因写清是 bridge 关闭），再杀进程树…')
    }
  }

  if (!(await waitFor(false, timeoutMs))) {
    console.error(`✗ ${timeoutMs}ms 内没退出：看 bridge/logs/bridge.log，必要时 npm run ps`)
    process.exit(1)
  }
  console.log('✓ bridge 已退出')
} else {
  console.log(`bridge 没在跑（${base}/health 连不上），无需停止`)
}

if (!restart) process.exit(0)

console.log('→ 重新启动 bridge（detached，等价于 Start-Process）…')
const pid = startBridge()
if (!(await waitFor(true, timeoutMs))) {
  console.error(`✗ 已拉起进程（pid ${pid}）但 ${base}/health 不通，看 bridge/logs/bridge.log`)
  process.exit(1)
}
console.log(`✓ bridge 已启动（pid ${pid}），${base}/health 正常`)
if (keepSession) {
  console.log('  提示：被保留的子进程仍在跑，登记文件还留在 `%TEMP%\\cline-hub-cmd\\running\\`；')
  console.log('        它退出后用 `npm run ps -- --clean` 收掉那条登记。')
}
