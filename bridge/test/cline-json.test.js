import assert from 'node:assert/strict'
import test from 'node:test'

import {
  createClineJsonParser,
  isClineJsonFailure,
  parseClineJsonLine
} from '../src/cline-json.js'

/**
 * 样本来自 2026-11-02 本机实跑 `cline --json`（3.0.74，隔离 data-dir）。
 * 保留真实字段名，避免以后 CLI 改字段时测试跟着「想当然」。
 */
const SUCCESS_LINES = [
  '{"ts":"2026-11-02T04:32:26.771Z","type":"hook_event","hookEventName":"agent_start","agentId":"agent_45eb8f39","taskId":"conv_1793593946761_emhq93x","parentAgentId":null}',
  '{"ts":"2026-11-02T04:32:26.774Z","type":"agent_event","event":{"type":"iteration_start","iteration":1}}',
  '{"ts":"2026-11-02T04:32:28.287Z","type":"agent_event","event":{"type":"content_start","contentType":"text","text":"OK","accumulated":"OK"}}',
  '{"ts":"2026-11-02T04:32:28.322Z","type":"agent_event","event":{"type":"usage","inputTokens":9000,"outputTokens":2,"totalCost":0.0013512}}',
  '{"ts":"2026-11-02T04:32:28.326Z","type":"agent_event","event":{"type":"content_end","contentType":"text","text":"OK"}}',
  '{"ts":"2026-11-02T04:32:28.329Z","type":"agent_event","event":{"type":"iteration_end","iteration":1,"hadToolCalls":false,"toolCallCount":0}}',
  '{"ts":"2026-11-02T04:32:28.332Z","type":"hook_event","hookEventName":"agent_end","agentId":"agent_45eb8f39","taskId":"conv_1793593946761_emhq93x","parentAgentId":null}',
  '{"ts":"2026-11-02T04:32:28.333Z","type":"agent_event","event":{"type":"done","reason":"completed","text":"OK","iterations":1,"usage":{"inputTokens":9000,"outputTokens":2,"totalCost":0.0013512}}}',
  '{"ts":"2026-11-02T04:32:28.723Z","type":"run_result","finishReason":"completed","iterations":1,"usage":{"inputTokens":9000,"outputTokens":2,"cacheReadTokens":0,"cacheWriteTokens":0,"totalCost":0.0013512},"aggregateUsage":{"inputTokens":9000,"outputTokens":2,"totalCost":0.0013512},"durationMs":1568,"text":"OK","model":{"id":"deepseek-flash","provider":"deepseek"}}'
]

const AUTH_ERROR_LINES = [
  '{"ts":"2026-11-02T04:31:57.021Z","type":"hook_event","hookEventName":"agent_start","agentId":"agent_556766e0","taskId":"conv_1793593917014_tgtj1l2","parentAgentId":null}',
  '{"ts":"2026-11-02T04:31:57.025Z","type":"agent_event","event":{"type":"iteration_start","iteration":1}}',
  '{"ts":"2026-11-02T04:31:57.473Z","type":"agent_event","event":{"type":"error","error":{"name":"Error","message":"Authentication Fails (governor)"},"errorClass":"auth","recoverable":false,"iteration":1}}',
  '{"ts":"2026-11-02T04:31:57.852Z","type":"error","message":"Authentication Fails (governor)"}'
]

const feed = (parser, lines) => {
  for (const line of lines) parser.push(`${line}\n`)
}

test('成功事件流：终稿 / taskId / 用量 / finishReason 都取到', () => {
  const parser = createClineJsonParser()
  feed(parser, SUCCESS_LINES)
  const json = parser.end()

  assert.equal(json.sawJson, true)
  assert.equal(json.jsonLines, SUCCESS_LINES.length)
  assert.equal(json.otherLines, 0)
  assert.equal(json.text, 'OK')
  assert.equal(json.finishReason, 'completed')
  assert.equal(json.taskId, 'conv_1793593946761_emhq93x')
  assert.equal(json.agentId, 'agent_45eb8f39')
  assert.equal(json.toolCalls, 0)
  assert.equal(json.iterations, 1)
  assert.equal(json.durationMs, 1568)
  assert.equal(json.model, 'deepseek-flash')
  assert.equal(json.provider, 'deepseek')
  assert.deepEqual(json.usage, { inputTokens: 9000, outputTokens: 2, totalCost: 0.0013512 })
  assert.equal(isClineJsonFailure(json), false)
})

test('认证失败：exit code 可能是 0，但事件里是 error，必须判失败', () => {
  const parser = createClineJsonParser()
  feed(parser, AUTH_ERROR_LINES)
  const json = parser.end()

  assert.equal(json.sawJson, true)
  assert.equal(json.text, '')
  assert.equal(json.finishReason, 'error')
  assert.equal(json.errorClass, 'auth')
  assert.equal(json.errorMessage, 'Authentication Fails (governor)')
  assert.equal(isClineJsonFailure(json), true)
})

test('数据块在任意位置截断也能拼回完整事件', () => {
  const parser = createClineJsonParser()
  const raw = SUCCESS_LINES.join('\n')
  // 每 7 个字符切一刀，覆盖「切在 JSON 中间 / 切在换行前」两种情况。
  for (let i = 0; i < raw.length; i += 7) parser.push(raw.slice(i, i + 7))
  const json = parser.end()

  assert.equal(json.text, 'OK')
  assert.equal(json.taskId, 'conv_1793593946761_emhq93x')
  assert.equal(json.sawJson, true)
})

test('最后一行没有换行时，end() 会 flush', () => {
  const parser = createClineJsonParser()
  parser.push(SUCCESS_LINES[SUCCESS_LINES.length - 1]) // 故意不带 \n
  const json = parser.end()
  assert.equal(json.text, 'OK')
  assert.equal(json.finishReason, 'completed')
})

test('非 JSON 噪声行被忽略，只计数，不影响后续解析', () => {
  const parser = createClineJsonParser()
  parser.push('Warning: something unrelated\r\n')
  parser.push('not json at all\n')
  parser.push(`${SUCCESS_LINES[SUCCESS_LINES.length - 1]}\n`)
  const json = parser.end()

  assert.equal(json.sawJson, true)
  assert.equal(json.otherLines, 2)
  assert.equal(json.text, 'OK')
})

test('run_result 比 agent_event.done 优先', () => {
  const parser = createClineJsonParser()
  parser.push('{"type":"agent_event","event":{"type":"done","reason":"completed","text":"早先的中间稿"}}\n')
  parser.push('{"type":"run_result","finishReason":"completed","text":"最终稿"}\n')
  assert.equal(parser.end().text, '最终稿')
})

test('终稿过长按上限截断并标记', () => {
  const parser = createClineJsonParser({ maxTextChars: 5 })
  parser.push('{"type":"run_result","finishReason":"completed","text":"ABCDEFGHIJ"}\n')
  const json = parser.end()
  assert.equal(json.text, 'ABCDE')
  assert.equal(json.textTruncated, true)
})

test('完全没有 JSON 时 isClineJsonFailure 为 false（退回原有 exit code 判断）', () => {
  const parser = createClineJsonParser()
  parser.push('plain terminal output\n')
  const json = parser.end()
  assert.equal(json.sawJson, false)
  assert.equal(isClineJsonFailure(json), false)
  assert.equal(isClineJsonFailure(null), false)
})

test('parseClineJsonLine 只接受完整对象行', () => {
  assert.deepEqual(parseClineJsonLine('{"a":1}'), { a: 1 })
  assert.equal(parseClineJsonLine('  {"a":1}  ').a, 1)
  assert.equal(parseClineJsonLine('{ not json'), null)
  assert.equal(parseClineJsonLine('Warning: x'), null)
  assert.equal(parseClineJsonLine(''), null)
  assert.equal(parseClineJsonLine('[]'), null)
})

