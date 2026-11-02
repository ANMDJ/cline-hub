import path from 'node:path'

import { projectInfo } from './project.js'

/**
 * 会话上报体的唯一构造入口。
 *
 * 正常采集（`index.js` 的 `emitSession`）和手工重发（`scripts/resend.mjs`）
 * 都走这里，否则两条路径的字段集合会慢慢漂移：重发一次反而把
 * `project*` 写回空白，比不重发更糟。
 */

/** 工作目录名：`C:\a\b\` → `b`（尾部分隔符不能进 basename）。 */
export function workspaceName(root) {
  if (!root) return ''
  const trimmed = String(root).replace(/[\\/]+$/, '')
  return path.basename(trimmed) || trimmed
}

export function isProcessAlive(pid) {
  if (!pid) return false
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    // EPERM = 进程存在但没权限，仍然算活着
    return error?.code === 'EPERM'
  }
}

/**
 * 真实状态：DB 里的 `status` 有两类不可信，都得在这里纠正。
 *
 * 1. cline 偶尔把**仍在跑**的会话短暂写成 `failed`（hook 派发失败时落一次），
 *    过一会儿又翻回 `running`；没有 `ended_at` 的那种，按「还在跑」算。
 * 2. 反过来，`status=running` 但进程早没了（比如昨天 VS Code 里的会话，pid 已回收），
 *    那是僵尸：一直显示「执行中」是假的，按 `failed` 处理，并且只通知一次。
 */
export function sessionState(row) {
  const status = String(row.status ?? '')
  const pidDead = Boolean(row.pid) && !isProcessAlive(row.pid)
  if (status === 'running') {
    if (pidDead) return { status: 'failed', zombie: true }
    return { status, zombie: false }
  }
  if (status === 'failed') {
    if (!row.ended_at) return { status: 'running', zombie: false }
    // 失败但进程已经没了：可能是真失败，也可能是僵尸会话在 failed/running 之间来回翻，
    // 统一打上 zombie 标记，交给节流和幂等去压。
    return { status: 'failed', zombie: pidDead }
  }
  return { status, zombie: false }
}

export function effectiveStatus(row) {
  return sessionState(row).status
}

export function toRecord(row, extraction) {
  const project = projectInfo(row.workspace_root)
  return {
    sessionId: row.session_id,
    source: row.source,
    status: effectiveStatus(row),
    exitCode: row.exit_code,
    provider: row.provider,
    model: row.model,
    cwd: row.cwd,
    workspaceRoot: row.workspace_root,
    workspace: workspaceName(row.workspace_root),
    // 项目根：从工作目录向上找 .git / 构建标记，找不到就归为散会话（loose）
    project: project.project,
    projectRoot: project.projectRoot,
    projectKind: project.projectKind,
    prompt: row.prompt ?? '',
    startedAt: row.started_at,
    endedAt: row.ended_at,
    updatedAt: row.updated_at,
    resultOk: extraction.ok,
    resultError: extraction.ok ? '' : (extraction.reason ?? ''),
    resultText: extraction.resultText,
    resultTruncated: extraction.resultTruncated,
    // 优先 messages.json 里最后一条"真人"输入；全是系统注入时退回 sessions.prompt。
    userPrompt: extraction.userPrompt || String(row.prompt ?? '').trim().slice(0, 2000),
    commands: extraction.commands,
    metrics: extraction.metrics,
    collectedAt: new Date().toISOString()
  }
}

/** 去重指纹：状态或 updated_at 变了才需要重发。 */
export function fingerprintOf(row) {
  return `${row.status ?? ''}|${row.updated_at ?? ''}`
}
