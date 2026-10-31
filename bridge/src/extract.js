import fs from 'node:fs'

function toText(value) {
  if (typeof value === 'string') return value
  if (Array.isArray(value)) return value.map(toText).filter(Boolean).join('\n')
  return ''
}

function cleanUserText(text) {
  return text
    .replace(/<user_input[^>]*>/g, '')
    .replace(/<\/user_input>/g, '')
    .trim()
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
  if (command.length > maxCommandChars) command = command.slice(0, maxCommandChars) + '\n... (truncated)'
  return { id: block.id ?? '', tool: name, command }
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
        if (role === 'assistant') resultText = text.trim()          // last one wins
        else if (role === 'user') userPrompt = cleanUserText(text)  // last one wins
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
