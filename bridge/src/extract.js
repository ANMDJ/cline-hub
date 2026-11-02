import fs from 'node:fs'

function toText(value) {
  if (typeof value === 'string') return value
  if (Array.isArray(value)) return value.map(toText).filter(Boolean).join('\n')
  return ''
}

const USER_INPUT_BLOCK = /<user_input[^>]*>([\s\S]*?)<\/user_input>/gi

/**
 * 只留用户真正输入的正文。
 *
 * Cline 给每条真人消息都裹一层 `<user_input mode="act">…</user_input>`，
 * 所以优先取包裹里的内容；没有包裹的再退化成剥标签。
 */
function cleanUserText(text) {
  const blocks = []
  for (const match of text.matchAll(USER_INPUT_BLOCK)) {
    const inner = match[1].trim()
    if (inner) blocks.push(inner)
  }
  if (blocks.length > 0) return blocks.join('\n').trim()
  return text
    .replace(/<user_input[^>]*>/g, '')
    .replace(/<\/user_input>/g, '')
    .trim()
}

/**
 * Cline 会把「继续上次任务」「hook 上下文」这类注入文本也塞进 user role：
 * `[TASK RESUMPTION] Please continue…`、`<hook_context source="ToolSuccess" …>`、
 * `<environment_details>` … 它们不是用户真正说的话，取最后一条 user text
 * 时必须跳过，否则真实 prompt 会被顶掉。
 */
function isInjectedUserText(text) {
  const value = text.trim()
  if (!value) return false
  if (/^\[(?:task resumption|system|automated|continue|resume)\b/i.test(value)) return true
  // 剩下的注入文本都以 XML 标签开头；真人输入很少这样（真这样时还有 sessions.prompt 兜底）。
  return value.startsWith('<')
}

function commandFromBlock(block, allowedTools, maxCommandChars) {
  if (!block || block.type !== 'tool_use') return null
  const name = String(block.name ?? '')
  if (allowedTools.length > 0 && !allowedTools.includes(name)) return null

  const input = block.input ?? {}
  let command = ''
  if (Array.isArray(input.commands)) {
    command = input.commands
      .map((item) => (typeof item === 'string' ? item : JSON.stringify(item)))
      .join('\n')
  } else if (typeof input.command === 'string') {
    command = input.command
  } else if (typeof input.commandLine === 'string') {
    command = input.commandLine
  }

  command = command.trim()
  if (!command) return null
  const truncated = command.length > maxCommandChars
  if (truncated) command = command.slice(0, maxCommandChars) + '\n... (truncated)'
  return { id: block.id ?? '', tool: name, command, truncated }
}

function clipText(text, limit) {
  if (text.length <= limit) return { text, truncated: false }
  return { text: `${text.slice(0, limit)}…[+${text.length - limit} chars]`, truncated: true }
}

/**
 * 逐条拍平 messages.json 的版本号。
 *
 * 上报端把「已处理到第几条」记进 state.json，服务端按
 * (device, session, message_id) upsert。抽取规则一旦改动就要 +1，
 * 否则老会话的水位线会被误认为「已经发全了」。
 */
export const TRANSCRIPT_VERSION = 2

/**
 * 把一条会话的 messages.json 拍平成手机能直接渲染的消息流。
 *
 * 只保留三类东西：
 *   - role=user 的真人输入（剥掉 `<user_input>` 包裹，跳过 `<environment_details>`
 *     这类注入文本；不然详情页第一屏全是系统提示）
 *   - role=assistant 的正文
 *   - 白名单工具的 tool_use（命令过程），tool_result / thinking 全部丢弃
 *
 * 每条都带稳定 id：messages.json 是追加写的，同一个 message 的 content 数组
 * 只会往后长，所以 `messageId + 块下标` 在会话生命周期内不会变，重发即覆盖。
 */
export function extractTranscript(messagesPath, options = {}) {
  const allowedTools = Array.isArray(options.commandTools) ? options.commandTools : []
  const maxTextChars = Number(options.maxTextChars) || 2000

  const failed = { ok: false, version: TRANSCRIPT_VERSION, total: 0, messages: [], reason: '' }
  if (!messagesPath) return { ...failed, reason: 'no messages_path' }

  let doc
  try {
    doc = JSON.parse(fs.readFileSync(messagesPath, 'utf8'))
  } catch (error) {
    return { ...failed, reason: `messages.json unreadable: ${error.message}` }
  }

  const raw = Array.isArray(doc) ? doc : (doc.messages ?? [])
  const messages = []

  for (const message of raw) {
    const role = message?.role === 'assistant' ? 'assistant' : 'user'
    const rawTs = Number(message?.ts)
    const ts = Number.isFinite(rawTs) ? new Date(rawTs).toISOString() : null
    const baseId = String(message?.id ?? '')
    if (!baseId) continue

    let index = 0
    for (const block of message?.content ?? []) {
      if (!block || typeof block !== 'object') continue

      if (block.type === 'text') {
        let text = toText(block.text).trim()
        if (!text) continue
        if (role === 'user') {
          text = cleanUserText(text)
          if (!text || isInjectedUserText(text)) continue
        }
        const clipped = clipText(text, maxTextChars)
        messages.push({
          id: `${baseId}:${index}`,
          role,
          kind: 'text',
          text: clipped.text,
          truncated: clipped.truncated,
          ts,
          seq: messages.length
        })
        index += 1
      } else if (block.type === 'tool_use') {
        // 「选择题」：Cline 的 ask_question 带 question + options，
        // 手机上必须能看见并点选，否则会话就卡在等待输入（2026-11-02 反馈）。
        if (block.name === 'ask_question') {
          const question = typeof block.input?.question === 'string'
            ? block.input.question.trim()
            : ''
          const options = Array.isArray(block.input?.options)
            ? block.input.options.map((item) => toText(item).trim()).filter(Boolean).slice(0, 8)
            : []
          if (question) {
            messages.push({
              id: `${baseId}:${index}`,
              role,
              kind: 'question',
              text: question,
              options,
              ts,
              seq: messages.length
            })
            index += 1
          }
          continue
        }
        const hit = commandFromBlock(block, allowedTools, maxTextChars)
        if (!hit) continue
        messages.push({
          id: `${baseId}:${index}`,
          role,
          kind: 'command',
          text: hit.command,
          truncated: hit.truncated === true,
          tool: hit.tool,
          ts,
          seq: messages.length
        })
        index += 1
      }
    }
  }

  return { ok: true, version: TRANSCRIPT_VERSION, total: messages.length, messages }
}

/**
 * Turn one session's messages.json into the compact record the Hub stores.
 * Only result text + whitelisted tool commands are kept; thinking and file
 * bodies are dropped on purpose (they dominate the file size and are useless
 * on a phone screen).
 */
export function extractSession(messagesPath, options = {}) {
  const allowedTools = Array.isArray(options.commandTools) ? options.commandTools : []
  const maxResultChars = Number(options.maxResultChars) || 4000
  const maxCommands = Number(options.maxCommands) || 300
  const maxCommandChars = Number(options.maxCommandChars) || 2000

  const empty = {
    ok: false,
    resultText: '',
    resultTruncated: false,
    userPrompt: '',
    commands: [],
    metrics: { messages: 0, thinkingChars: 0, commandCount: 0 }
  }

  if (!messagesPath) return { ...empty, reason: 'no messages_path' }

  let doc
  try {
    doc = JSON.parse(fs.readFileSync(messagesPath, 'utf8'))
  } catch (error) {
    return { ...empty, reason: `messages.json unreadable: ${error.message}` }
  }

  const messages = Array.isArray(doc) ? doc : (doc.messages ?? [])
  let resultText = ''
  let userPrompt = ''
  let thinkingChars = 0
  const commands = []

  for (const message of messages) {
    const role = message?.role
    for (const block of message?.content ?? []) {
      if (!block || typeof block !== 'object') continue

      if (block.type === 'text') {
        const text = toText(block.text)
        if (!text.trim()) continue
        if (role === 'assistant') {
          resultText = text.trim() // last one wins
        } else if (role === 'user') {
          const cleaned = cleanUserText(text)
          // last 真实用户输入 wins；系统注入的恢复/提示文本不覆盖它。
          if (cleaned && !isInjectedUserText(cleaned)) userPrompt = cleaned
        }
      } else if (block.type === 'thinking') {
        thinkingChars += String(block.thinking ?? '').length
      } else if (block.type === 'tool_use') {
        const hit = commandFromBlock(block, allowedTools, maxCommandChars)
        if (hit && commands.length < maxCommands) commands.push(hit)
      }
    }
  }

  let resultTruncated = false
  if (resultText.length > maxResultChars) {
    resultText = resultText.slice(0, maxResultChars)
    resultTruncated = true
  }

  return {
    ok: true,
    resultText,
    resultTruncated,
    userPrompt: userPrompt.slice(0, 2000),
    commands,
    metrics: {
      messages: messages.length,
      thinkingChars,
      commandCount: commands.length
    }
  }
}
