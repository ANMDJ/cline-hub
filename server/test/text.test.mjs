import assert from 'node:assert/strict'
import test from 'node:test'

import { PREVIEW_CHARS, plainPreview, stripAnsi, stripMarkdown } from '../src/text.js'

test('stripAnsi 去掉颜色序列与光标控制', () => {
  assert.equal(
    stripAnsi('\u001b[2mThe\u001b[0m \u001b[32muser\u001b[0m\u001b[?25l'),
    'The user'
  )
})

test('stripMarkdown 保留文字，去掉记号', () => {
  assert.equal(stripMarkdown('# 标题'), '标题')
  assert.equal(stripMarkdown('> 引用'), '引用')
  assert.equal(stripMarkdown('**粗** 与 *斜* 与 ~~删~~'), '粗 与 斜 与 删')
  assert.equal(stripMarkdown('`npm test` 通过'), 'npm test 通过')
  assert.equal(stripMarkdown('见 [文档](https://example.com/a?b=1)'), '见 文档')
})

test('plainPreview 把多段 Markdown 折成一句话', () => {
  const raw = [
    '## 结论：可以',
    '',
    '我试了 `kids.pem`，**成功**：',
    '',
    '```powershell',
    'ssh -i kids.pem',
    '```',
    '',
    '- 第一点',
    '- 第二点'
  ].join('\n')
  assert.equal(
    plainPreview(raw),
    '结论：可以 我试了 kids.pem，成功： ssh -i kids.pem 第一点 第二点'
  )
})

test('表格行去掉竖线，分隔行整行丢弃', () => {
  assert.equal(
    plainPreview('| 项 | 值 |\n|---|:---:|\n| 端口 | 8443 |'),
    '项 值 端口 8443'
  )
})

test('被截断的半个转义序列不会漏进预览', () => {
  assert.equal(plainPreview('[2m 风险可控'), '风险可控')
  assert.equal(stripAnsi('\u001b['), '')
})

test('下划线命名不会被当成斜体吃掉', () => {
  const raw = 'maxTextChars 和 TRANSCRIPT_VERSION 都不动'
  assert.equal(plainPreview(raw), raw)
})

test('按码点截断：不劈开 emoji，结尾加省略号', () => {
  const raw = '🙂'.repeat(10) + 'x'.repeat(40)
  const out = plainPreview(raw, 15)
  assert.equal(Array.from(out).length, 16, '15 个码点 + 省略号')
  assert.ok(out.endsWith('…'))
  assert.ok(!/[\ud800-\udbff](?![\udc00-\udfff])/.test(out), '没有孤立代理项')
})

test('空内容与非字符串返回空串', () => {
  assert.equal(plainPreview(null), '')
  assert.equal(plainPreview('   \n\t '), '')
  assert.equal(plainPreview('正常文本'), '正常文本')
})

test('默认上限是 400 字', () => {
  const out = plainPreview('字'.repeat(1000))
  assert.equal(Array.from(out).length, PREVIEW_CHARS + 1)
})
