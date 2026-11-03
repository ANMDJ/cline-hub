import assert from 'node:assert/strict'
import test from 'node:test'

import { HttpError } from '../src/http.js'
import {
  createAttachmentRoutes,
  decodeAttachmentData,
  safeAttachmentName,
  toAttachment
} from '../src/routes/attachments.js'
import { createCommandRoutes } from '../src/routes/commands.js'

/**
 * P38：手机端「发送文件 / 图片」。
 *
 * 这里只测纯逻辑与路由的校验分支（不需要真数据库）：
 *   * 文件名 / base64 / 大小上限的边界；
 *   * 附件必须属于目标设备（app 不能借别的设备的附件）；
 *   * device token 只能下载自己的附件；
 *   * 命令可以「只带附件不带 prompt」，但两个都空要 400。
 */

const logger = { info() {}, warn() {}, error() {}, debug() {} }
const sse = { broadcast() {} }
const app = { id: 'phone', role: 'app' }
const device = { id: 'localone', role: 'device' }

function pick(routes, pattern, method = 'GET') {
  const route = routes.find((item) => item.pattern === pattern && item.method === method)
  assert.ok(route, `${method} ${pattern} not found`)
  return route
}

/** 记录 SQL 的最小 db 替身：每条 SQL 交给 handlers 决定返回什么。 */
function fakeDb({ one, many } = {}) {
  const calls = []
  return {
    calls,
    db: {
      async one(sql, params) {
        calls.push({ kind: 'one', sql: String(sql), params })
        return one ? one(String(sql), params) : null
      },
      async many(sql, params) {
        calls.push({ kind: 'many', sql: String(sql), params })
        return many ? many(String(sql), params) : []
      }
    }
  }
}

async function expectHttpError(promise, status, code) {
  try {
    await promise
  } catch (error) {
    assert.ok(error instanceof HttpError, `expected HttpError, got ${error}`)
    assert.equal(error.status, status)
    if (code) assert.equal(error.code, code)
    return error
  }
  assert.fail('expected an HttpError')
}

test('safeAttachmentName：去掉路径与控制字符，空值有兜底', () => {
  assert.equal(safeAttachmentName('report.pdf'), 'report.pdf')
  assert.equal(safeAttachmentName('C:\\Users\\alice\\a b.png'), 'a b.png')
  assert.equal(safeAttachmentName('/sdcard/DCIM/a?b*c.jpg'), 'a_b_c.jpg')
  assert.equal(safeAttachmentName('../../etc/passwd'), 'passwd')
  assert.equal(safeAttachmentName('  ..  '), 'attachment')
  assert.equal(safeAttachmentName(null), 'attachment')
  assert.equal(safeAttachmentName('x'.repeat(200)).length, 120)
})

test('decodeAttachmentData：正常 base64 → Buffer，非法 / 空 / 超限分别报错', () => {
  assert.equal(decodeAttachmentData('aGVsbG8=', 1024).toString('utf8'), 'hello')

  assert.throws(() => decodeAttachmentData('', 1024), /must be a base64 string/)
  assert.throws(() => decodeAttachmentData('not***base64', 1024), /not valid base64/)

  const big = Buffer.alloc(2048, 7).toString('base64')
  assert.throws(
    () => decodeAttachmentData(big, 1024),
    (error) =>
      error instanceof HttpError && error.status === 413 && error.code === 'attachment_too_large'
  )
})

test('toAttachment：只给元数据（含入库时间），不带内容', () => {
  assert.equal(toAttachment(null), null)
  assert.deepEqual(
    toAttachment({
      id: 'att_1',
      name: 'a.png',
      mime_type: 'image/png',
      byte_size: 12,
      created_at: '2026-11-03T04:30:00.000Z',
      data: Buffer.from('secret')
    }),
    {
      id: 'att_1',
      name: 'a.png',
      mimeType: 'image/png',
      byteSize: 12,
      // 入库时间：附件落进 Hub 的时刻（保留策略以后按它清理）
      createdAt: '2026-11-03T04:30:00.000Z'
    }
  )
})

test('POST /attachments：未知设备 400，正常落库返回元数据', async () => {
  const unknown = fakeDb({ one: () => null })
  const unknownRoutes = createAttachmentRoutes({
    db: unknown.db,
    logger,
    config: { maxAttachmentBytes: 1024 }
  })
  await expectHttpError(
    pick(unknownRoutes, '/api/v1/attachments', 'POST').handler({
      body: { deviceId: 'ghost', name: 'a.txt', data: 'aGVsbG8=' },
      client: app
    }),
    400,
    'unknown_device'
  )

  const stored = fakeDb({
    one(sql, params) {
      if (sql.includes('from clients')) return { id: 'localone' }
      if (sql.startsWith('select id, name, mime_type, byte_size')) return null
      if (sql.includes('insert into attachments')) {
        return {
          id: params[0],
          name: params[2],
          mime_type: params[3],
          byte_size: params[4],
          created_at: '2026-11-03T04:30:00.000Z'
        }
      }
      return null
    }
  })
  const routes = createAttachmentRoutes({
    db: stored.db,
    logger,
    config: { maxAttachmentBytes: 1024 }
  })
  const result = await pick(routes, '/api/v1/attachments', 'POST').handler({
    body: { deviceId: 'localone', name: 'hello.txt', mimeType: 'text/plain', data: 'aGVsbG8=' },
    client: app
  })
  assert.equal(result.ok, true)
  assert.equal(result.attachment.name, 'hello.txt')
  assert.equal(result.attachment.byteSize, 5)
  assert.equal(result.attachment.createdAt, '2026-11-03T04:30:00.000Z')
  assert.match(result.attachment.id, /^att_[0-9a-f]{16}$/)
})
test('POST /attachments：同名同内容复用，不重复存', async () => {
  const { db } = fakeDb({
    one(sql) {
      if (sql.includes('from clients')) return { id: 'localone' }
      if (sql.startsWith('select id, name, mime_type, byte_size')) {
        return {
          id: 'att_reused',
          name: 'hello.txt',
          mime_type: 'text/plain',
          byte_size: 5,
          created_at: '2026-11-03T04:30:00.000Z'
        }
      }
      throw new Error('不该走到 insert')
    }
  })
  const routes = createAttachmentRoutes({ db, logger, config: { maxAttachmentBytes: 1024 } })
  const result = await pick(routes, '/api/v1/attachments', 'POST').handler({
    body: { deviceId: 'localone', name: 'hello.txt', data: 'aGVsbG8=' },
    client: app
  })
  assert.equal(result.reused, true)
  assert.equal(result.attachment.id, 'att_reused')
})



test('GET /attachments/:id：device 只能下载自己的，app 都能下', async () => {
  const row = {
    id: 'att_1',
    device_id: 'otherpc',
    name: 'a.txt',
    mime_type: 'text/plain',
    byte_size: 5,
    data: Buffer.from('hello')
  }
  const { db } = fakeDb({ one: () => row })
  const routes = createAttachmentRoutes({ db, logger, config: {} })

  await expectHttpError(
    pick(routes, '/api/v1/attachments/:id').handler({
      params: { id: 'att_1' },
      res: {},
      client: device
    }),
    403,
    'forbidden'
  )

  const written = []
  const fakeRes = {
    writeHead(status, headers) {
      written.push({ status, headers })
    },
    end(body) {
      written.push({ body })
    }
  }
  const result = await pick(routes, '/api/v1/attachments/:id').handler({
    params: { id: 'att_1' },
    res: fakeRes,
    client: app
  })
  assert.equal(result, undefined, '自己写完响应时返回 undefined')
  assert.equal(written[0].status, 200)
  assert.equal(written[0].headers['content-type'], 'text/plain')
  assert.equal(written[1].body.toString('utf8'), 'hello')
})

test('POST /commands：只带附件可以不带 prompt；两个都空要 400', async () => {
  const attachmentRow = {
    id: 'att_1',
    device_id: 'localone',
    name: 'a.png',
    mime_type: 'image/png',
    byte_size: 3
  }
  const { db } = fakeDb({
    one(sql) {
      if (sql.includes('from clients')) return { id: 'localone' }
      if (sql.includes('from attachments')) return attachmentRow
      if (sql.includes('insert into commands')) {
        return {
          id: 'cmd_1',
          device_id: 'localone',
          prompt: '',
          mode: 'plan',
          workspace: null,
          session_id: null,
          status: 'pending',
          requested_by: 'phone',
          attachment_id: 'att_1'
        }
      }
      return null
    },
    many() {
      return [attachmentRow]
    }
  })
  const routes = createCommandRoutes({ db, logger, sse })
  const route = pick(routes, '/api/v1/commands', 'POST')

  const created = await route.handler({
    body: { deviceId: 'localone', prompt: '', attachmentId: 'att_1' },
    client: app
  })
  assert.equal(created.command.attachment.id, 'att_1')
  assert.equal(created.command.prompt, '')

  await expectHttpError(
    route.handler({ body: { deviceId: 'localone', prompt: '' }, client: app }),
    400,
    'invalid_field'
  )
})

test('POST /commands：附件属于别的设备 → 403', async () => {
  const { db } = fakeDb({
    one(sql) {
      if (sql.includes('from clients')) return { id: 'localone' }
      if (sql.includes('from attachments')) return { id: 'att_1', device_id: 'otherpc' }
      return null
    }
  })
  const routes = createCommandRoutes({ db, logger, sse })
  await expectHttpError(
    pick(routes, '/api/v1/commands', 'POST').handler({
      body: { deviceId: 'localone', prompt: '看看这个文件', attachmentId: 'att_1' },
      client: app
    }),
    403,
    'forbidden'
  )
})


