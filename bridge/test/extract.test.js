import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'

import { extractTranscript, TRANSCRIPT_VERSION } from '../src/extract.js'

function writeMessages(messages) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cline-hub-test-'))
  const file = path.join(dir, 'messages.json')
  fs.writeFileSync(file, JSON.stringify({ messages }), 'utf8')
  return file
}

const OPTIONS = { commandTools: ['run_commands'], maxTextChars: 2000 }

test('长文本被截断并标记 truncated', () => {
  const file = writeMessages([
    { id: 'm1', role: 'assistant', ts: 1, content: [{ type: 'text', text: 'x'.repeat(5000) }] }
  ])
  const result = extractTranscript(file, OPTIONS)
  assert.equal(result.ok, true)
  assert.equal(result.version, TRANSCRIPT_VERSION)
  const [message] = result.messages
  assert.equal(message.truncated, true)
  assert.ok(message.text.length < 2100)
  assert.match(message.text, /\[\+3000 chars\]$/)
})

test('短文本不标记截断', () => {
  const file = writeMessages([
    { id: 'm1', role: 'assistant', ts: 1, content: [{ type: 'text', text: '短回复' }] }
  ])
  const [message] = extractTranscript(file, OPTIONS).messages
  assert.equal(message.truncated, false)
  assert.equal(message.text, '短回复')
})

test('ask_question 抽成 kind=question 并带上 options', () => {
  const file = writeMessages([
    {
      id: 'm1',
      role: 'assistant',
      ts: 1,
      content: [
        {
          type: 'tool_use',
          name: 'ask_question',
          input: { question: '选哪个方案？', options: ['A', ' B ', ''] }
        }
      ]
    }
  ])
  const [message] = extractTranscript(file, OPTIONS).messages
  assert.equal(message.kind, 'question')
  assert.equal(message.text, '选哪个方案？')
  assert.deepEqual(message.options, ['A', 'B'])
})

test('超长命令标记 truncated', () => {
  const file = writeMessages([
    {
      id: 'm1',
      role: 'assistant',
      ts: 1,
      content: [
        { type: 'tool_use', name: 'run_commands', input: { command: 'echo ' + 'a'.repeat(50) } }
      ]
    }
  ])
  const [message] = extractTranscript(file, { commandTools: ['run_commands'], maxTextChars: 20 }).messages
  assert.equal(message.kind, 'command')
  assert.equal(message.truncated, true)
})
