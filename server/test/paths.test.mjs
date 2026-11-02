import assert from 'node:assert/strict'
import test from 'node:test'

import { normalizeFsPath } from '../src/util.js'
import { createCommandRoutes } from '../src/routes/commands.js'
import { createSessionRoutes, toListItem } from '../src/routes/sessions.js'

const logger = { info() {}, warn() {}, error() {}, debug() {} }
const sse = { broadcast() {} }
const device = { id: 'localone', role: 'device' }

function pick(routes, pattern, method = 'GET') {
  const route = routes.find((item) => item.pattern === pattern && item.method === method)
  assert.ok(route, `${method} ${pattern} not found`)
  return route
}

/** 记录 SQL 与参数的最小 db 替身；`one` 固定返回 row，够接口跑完就行。 */
function capture(row = null) {
  const calls = []
  const db = {
    async many(sql, params) {
      calls.push({ kind: 'many', sql: String(sql), params })
      return []
    },
    async one(sql, params) {
      calls.push({ kind: 'one', sql: String(sql), params })
      return row
    }
  }
  return { calls, db }
}

test('normalizeFsPath：正斜杠 / 重复斜杠 / 尾斜杠统一成 Windows 写法', () => {
  assert.equal(
    normalizeFsPath('C:/Users/alice/.cline/data/workspaces/chat/cline-hub'),
    'C:\\Users\\alice\\.cline\\data\\workspaces\\chat\\cline-hub'
  )
  assert.equal(normalizeFsPath('C:\\Users\\\\alice\\'), 'C:\\Users\\alice')
  assert.equal(normalizeFsPath('c:/a/b/'), 'c:\\a\\b')
  assert.equal(normalizeFsPath('C:\\'), 'C:\\', '盘符根不能退化成 C:')
  assert.equal(normalizeFsPath('C:/'), 'C:\\')
})

test('normalizeFsPath：不动大小写，也不碰 POSIX / 相对路径', () => {
  assert.equal(normalizeFsPath('C:\\Users\\ALICE\\App'), 'C:\\Users\\ALICE\\App')
  assert.equal(normalizeFsPath('/home/me/app/'), '/home/me/app/')
  assert.equal(normalizeFsPath('kids_points_app'), 'kids_points_app')
  assert.equal(normalizeFsPath(null), null)
  assert.equal(normalizeFsPath(''), '')
  assert.equal(normalizeFsPath('   '), '')
})

test('normalizeFsPath：UNC 的两个前导反斜杠保留', () => {
  assert.equal(normalizeFsPath('\\\\server/share/'), '\\\\server\\share')
})

test('POST /sessions 入库前把 workspaceRoot / projectRoot 归一化', async () => {
  const { calls, db } = capture({ inserted: true })
  const route = pick(createSessionRoutes({ db, logger, sse }), '/api/v1/sessions', 'POST')

  await route.handler({
    client: device,
    body: {
      session: {
        sessionId: 's1',
        workspace: 'app',
        workspaceRoot: 'C:/Users/alice/projects/app/',
        project: 'app',
        projectRoot: 'C:/Users/alice/projects/app',
        projectKind: 'project'
      }
    }
  })

  const params = calls[0].params
  assert.equal(params[3], 'C:\\Users\\alice\\projects\\app')
  assert.equal(params[22], 'C:\\Users\\alice\\projects\\app')
})

test('列表输出把历史行里的正斜杠统一成反斜杠', () => {
  const item = toListItem({
    device_id: 'localone',
    session_id: 's1',
    workspace: 'cline-hub',
    workspace_root: 'C:/Users/alice/.cline/data/workspaces/chat/cline-hub',
    project: '',
    project_root: '',
    project_kind: null
  })

  assert.equal(
    item.workspaceRoot,
    'C:\\Users\\alice\\.cline\\data\\workspaces\\chat\\cline-hub'
  )
  assert.equal(item.projectRoot, '')
})

test('POST /commands 把 workspace 归一化后入库', async () => {
  const { calls, db } = capture({ id: 'localone' })
  const route = pick(createCommandRoutes({ db, logger, sse }), '/api/v1/commands', 'POST')

  await route.handler({
    client: { id: 'phone', role: 'app' },
    body: {
      deviceId: 'localone',
      prompt: '跑一遍测试',
      workspace: 'C:/Users/alice/projects/app'
    }
  })

  const insert = calls.find((call) => /insert into commands/.test(call.sql))
  assert.ok(insert, 'should insert the command')
  assert.equal(insert.params[4], 'C:\\Users\\alice\\projects\\app')
})
