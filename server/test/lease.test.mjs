import assert from 'node:assert/strict'
import test from 'node:test'

import {
  createCommandLease,
  LEASE_CANCEL_ERROR,
  LEASE_ORPHAN_ERROR
} from '../src/lease.js'

/**
 * P42：命令租约回收。
 *
 * 这里不连真库：`sweep()` 只做三件事 —— 选过期行、批量改状态、广播。
 * 用假 client 断言「SQL 里的状态映射」与「广播的负载形状」，
 * 真库那一侧由线上 smoke / 手工验证覆盖（见 docs/status.md）。
 */

const silentLogger = { info() {}, warn() {}, error() {} }

function row(id, status, extra = {}) {
  return {
    id,
    device_id: 'localone',
    prompt: '跑一遍测试',
    mode: 'act',
    workspace: 'C:\\work\\kids_points_app',
    session_id: null,
    status,
    requested_by: 'phone',
    runner: 'cline',
    pid: 4242,
    pid_started_at: null,
    result_text: null,
    error_text: null,
    created_at: '2026-11-02T03:00:00.000Z',
    delivered_at: '2026-11-02T03:00:01.000Z',
    started_at: null,
    finished_at: null,
    cancel_requested_at: null,
    lease_expires_at: '2026-11-02T03:00:00.000Z',
    attachment_id: null,
    ...extra
  }
}

function harness(expiredRows, { attachments = [] } = {}) {
  const queries = []
  const broadcasts = []
  const db = {
    async tx(fn) {
      const client = {
        async query(sql, params) {
          queries.push({ sql, params })
          return String(sql).trimStart().startsWith('select')
            ? { rows: expiredRows.map((item) => ({ id: item.id })) }
            : { rows: expiredRows }
        }
      }
      return fn(client)
    },
    async many() {
      return attachments
    }
  }
  const lease = createCommandLease({
    db,
    logger: silentLogger,
    sse: { broadcast: (event, payload) => broadcasts.push({ event, payload }) },
    config: { commandLeaseSweepMs: 60_000 }
  })
  return { lease, queries, broadcasts }
}

test('没有过期租约：只查一次，不改状态也不广播', async () => {
  const { lease, queries, broadcasts } = harness([])

  const result = await lease.sweep()

  assert.deepEqual(result, { ok: true, reclaimed: 0, ids: [] })
  assert.equal(queries.length, 1)
  assert.equal(broadcasts.length, 0)
})

test('过期 running：收成 failed，原因说清「不是命令本身失败」', async () => {
  const { lease, queries, broadcasts } = harness([
    row('cmd_lease_1', 'failed', { error_text: LEASE_ORPHAN_ERROR, lease_expires_at: null })
  ])

  const result = await lease.sweep()

  assert.equal(result.reclaimed, 1)
  assert.deepEqual(result.ids, ['cmd_lease_1'])

  // 更新语句：delivered / running → failed，cancelling → cancelled，并清空租约
  assert.match(queries[1].sql, /when status = 'cancelling' then 'cancelled'/)
  assert.match(queries[1].sql, /lease_expires_at = null/)
  assert.deepEqual(queries[1].params, [
    ['cmd_lease_1'],
    LEASE_CANCEL_ERROR,
    LEASE_ORPHAN_ERROR
  ])

  assert.equal(broadcasts.length, 1)
  assert.equal(broadcasts[0].event, 'command.update')
  assert.equal(broadcasts[0].payload.id, 'cmd_lease_1')
  assert.equal(broadcasts[0].payload.status, 'failed')
  assert.equal(broadcasts[0].payload.errorText, LEASE_ORPHAN_ERROR)
})

test('过期 cancelling：按「已取消」收尾，不显示成失败', async () => {
  const { lease, broadcasts } = harness([
    row('cmd_lease_2', 'cancelled', { error_text: LEASE_CANCEL_ERROR })
  ])

  await lease.sweep()

  assert.equal(broadcasts[0].payload.status, 'cancelled')
  assert.equal(broadcasts[0].payload.errorText, LEASE_CANCEL_ERROR)
})

test('带附件的命令：广播里保留附件元数据（手机上的附件卡片不能消失）', async () => {
  const { lease, broadcasts } = harness(
    [row('cmd_lease_3', 'failed', { attachment_id: 'att_1' })],
    {
      attachments: [
        { id: 'att_1', name: '报告.docx', mime_type: 'application/msword', byte_size: 12, created_at: '2026-11-02T03:00:00.000Z' }
      ]
    }
  )

  await lease.sweep()

  assert.equal(broadcasts[0].payload.attachment.id, 'att_1')
  assert.equal(broadcasts[0].payload.attachment.name, '报告.docx')
})

test('上一轮还没跑完时，下一轮直接跳过（不会叠加扫描）', async () => {
  let release
  const gate = new Promise((resolve) => {
    release = resolve
  })
  const broadcasts = []
  const db = {
    async tx(fn) {
      await gate
      return fn({
        async query(sql) {
          return String(sql).trimStart().startsWith('select')
            ? { rows: [{ id: 'cmd_slow' }] }
            : { rows: [row('cmd_slow', 'failed')] }
        }
      })
    },
    async many() {
      return []
    }
  }
  const lease = createCommandLease({
    db,
    logger: silentLogger,
    sse: { broadcast: (event, payload) => broadcasts.push({ event, payload }) },
    config: { commandLeaseSweepMs: 60_000 }
  })

  const first = lease.sweep()
  const second = await lease.sweep()
  assert.equal(second.skipped, 'busy')

  release()
  const done = await first
  assert.equal(done.reclaimed, 1)
  assert.equal(broadcasts.length, 1)
})
