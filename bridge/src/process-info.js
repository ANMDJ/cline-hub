import { spawnSync } from 'node:child_process'

/**
 * 按 pid 查进程：Windows 用 CIM 连创建时间一起取，其他平台只能确认存活。
 *
 * 单独抽一层的理由：两个调用方必须用同一套判定 ——
 *   - `npm run ps` 决定「这条登记还能不能杀」；
 *   - `command-worker.reconcile()` 决定「Hub 上 running 的命令是不是已经没了」。
 * 两边各写一份 PowerShell 查询，迟早会出现「ps 说还在跑、对账说孤儿」的矛盾。
 *
 * 返回 `Map<number, { pid, parentPid, name, startedAtMs }>`；
 * 非 Windows 的 `startedAtMs` 固定是 0（拿不到，见 `processLiveness()` 的降级规则）。
 */
export function inspectProcesses(pids) {
  const wanted = [...new Set(pids.map(Number).filter((pid) => Number.isInteger(pid) && pid > 0))]
  if (wanted.length === 0) return new Map()
  return process.platform === 'win32' ? inspectWindows(wanted) : inspectPosix(wanted)
}

function inspectWindows(pids) {
  const filter = pids.map((id) => `ProcessId=${id}`).join(' or ')
  const script = [
    '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8',
    `$rows = Get-CimInstance Win32_Process -Filter "${filter}" | ForEach-Object {`,
    '  [pscustomobject]@{',
    '    pid = [int]$_.ProcessId',
    '    parentPid = [int]$_.ParentProcessId',
    '    name = [string]$_.Name',
    "    startedAtMs = [long](($_.CreationDate.ToUniversalTime() - [datetime]'1970-01-01').TotalMilliseconds)",
    '  }',
    '}',
    '[pscustomobject]@{ items = @($rows) } | ConvertTo-Json -Compress -Depth 4'
  ].join('\n')

  const result = spawnSync(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script],
    // 查询失败不让调用方整体挂掉：对账会宁可「不判死」，ps 会显示「进程已不在」。
    { encoding: 'utf8', windowsHide: true, timeout: 20000 }
  )
  if (result.status !== 0 || !result.stdout) {
    throw new Error(`PowerShell 查询失败：${(result.stderr || result.stdout || '').trim() || `exit ${result.status}`}`)
  }
  const parsed = JSON.parse(result.stdout)
  const items = Array.isArray(parsed?.items) ? parsed.items : parsed?.items ? [parsed.items] : []
  return new Map(items.map((item) => [Number(item.pid), item]))
}

function inspectPosix(pids) {
  const map = new Map()
  for (const pid of pids) {
    try {
      process.kill(pid, 0)
      map.set(pid, { pid, parentPid: 0, name: '', startedAtMs: 0 })
    } catch {}
  }
  return map
}
