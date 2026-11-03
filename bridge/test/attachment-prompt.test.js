import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'

import {
  composePrompt,
  formatBytes,
  safeFileName,
  saveAttachment
} from '../src/attachment.js'

/**
 * P38：手机发来的附件在 bridge 侧怎么落地。
 *
 * 重点不是「能不能下载」，而是**拼出来的 prompt 有没有把文件的绝对路径说清楚**：
 * 路径错了 / 少了这句，cline 就会自己猜，然后在手机上看不出是附件没送到。
 */

async function withServer(handler, run) {
  const server = http.createServer(handler)
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  const { port } = server.address()
  try {
    return await run(`http://127.0.0.1:${port}`)
  } finally {
    await new Promise((resolve) => server.close(resolve))
  }
}

test('safeFileName：去掉路径与 Windows 不接受的字符', () => {
  assert.equal(safeFileName('report.pdf'), 'report.pdf')
  assert.equal(safeFileName('C:\\Users\\alice\\a b.png'), 'a b.png')
  assert.equal(safeFileName('/sdcard/a?b*c.jpg'), 'a_b_c.jpg')
  assert.equal(safeFileName('../../etc/passwd'), 'passwd')
  assert.equal(safeFileName('..'), 'attachment')
  assert.equal(safeFileName(''), 'attachment')
  assert.equal(safeFileName(null), 'attachment')
  assert.equal(safeFileName('CON'), '_CON', 'Windows 保留设备名前加下划线')
})

test('formatBytes：B / KB / MB 的可读写法', () => {
  assert.equal(formatBytes(0), '0 B')
  assert.equal(formatBytes(999), '999 B')
  assert.equal(formatBytes(1024), '1.0 KB')
  assert.equal(formatBytes(1024 * 1024 * 3), '3.0 MB')
  assert.equal(formatBytes(null), '0 B')
})

test('composePrompt：带说明时保留原话并给出绝对路径', () => {
  const text = composePrompt({
    caption: '把这份周报里的错别字改掉',
    filePath: 'C:\\Temp\\incoming\\cmd_1-周报.docx',
    name: '周报.docx',
    mimeType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    byteSize: 2048
  })
  assert.ok(text.startsWith('把这份周报里的错别字改掉\n\n'), '用户原话必须在最前面')
  assert.match(text, /路径：C:\\Temp\\incoming\\cmd_1-周报\.docx/)
  assert.match(text, /原名：周报\.docx/)
  assert.match(text, /2\.0 KB/)
  assert.match(text, /请先读取这个文件，再按上面的要求处理。/)
})

test('composePrompt：只发文件（没写说明）也要给出明确指令', () => {
  const text = composePrompt({
    caption: '   ',
    filePath: '/tmp/cmd_2-shot.png',
    name: 'shot.png',
    mimeType: 'image/png',
    byteSize: 512
  })
  assert.ok(text.startsWith('[附件]'), '没有用户原话时不要留空行')
  assert.match(text, /路径：\/tmp\/cmd_2-shot\.png/)
  assert.match(text, /先不要修改任何文件/)
})

test('saveAttachment：下载后落盘，路径与内容都对', async () => {
  const dir = path.join(os.tmpdir(), `cline-hub-att-test-${process.pid}`)
  fs.rmSync(dir, { recursive: true, force: true })

  await withServer(
    (req, res) => {
      assert.equal(req.url, '/api/v1/attachments/att_abc')
      assert.equal(req.headers.authorization, 'Bearer testtoken')
      res.writeHead(200, { 'content-type': 'image/png' })
      res.end(Buffer.from([0x89, 0x50, 0x4e, 0x47]))
    },
    async (hubUrl) => {
      const saved = await saveAttachment({
        hubUrl,
        token: 'testtoken',
        attachment: { id: 'att_abc', name: '../shot.png', mimeType: 'image/png' },
        dir,
        commandId: 'cmd_1'
      })
      assert.equal(saved.name, 'shot.png')
      assert.equal(saved.byteSize, 4)
      assert.equal(saved.mimeType, 'image/png')
      assert.equal(path.basename(saved.filePath), 'cmd_1-shot.png')
      assert.deepEqual([...fs.readFileSync(saved.filePath)], [0x89, 0x50, 0x4e, 0x47])
    }
  )

  fs.rmSync(dir, { recursive: true, force: true })
})

test('saveAttachment：404 / 空内容 / 超限都抛错（由上层回写 failed）', async () => {
  const dir = path.join(os.tmpdir(), `cline-hub-att-test-err-${process.pid}`)

  await withServer(
    (req, res) => {
      if (req.url.endsWith('/missing')) {
        res.writeHead(404, { 'content-type': 'application/json' })
        res.end('{"ok":false,"message":"attachment not found"}')
        return
      }
      if (req.url.endsWith('/empty')) {
        res.writeHead(200)
        res.end()
        return
      }
      res.writeHead(200)
      res.end(Buffer.alloc(64, 1))
    },
    async (hubUrl) => {
      await assert.rejects(
        saveAttachment({
          hubUrl,
          token: 't',
          attachment: { id: 'missing', name: 'a.txt' },
          dir,
          commandId: 'cmd_1'
        }),
        /404/
      )
      await assert.rejects(
        saveAttachment({
          hubUrl,
          token: 't',
          attachment: { id: 'empty', name: 'a.txt' },
          dir,
          commandId: 'cmd_1'
        }),
        /0 字节/
      )
      await assert.rejects(
        saveAttachment({
          hubUrl,
          token: 't',
          attachment: { id: 'big', name: 'a.txt' },
          dir,
          commandId: 'cmd_1',
          maxBytes: 16
        }),
        /超过/
      )
    }
  )

  fs.rmSync(dir, { recursive: true, force: true })
})
