/**
 * `cline --json` 的 NDJSON 解析器。
 *
 * 为什么需要它（2026-11-02）：bridge 以前把 cline 的 stdout/stderr 原样当结果回写，
 * 手机上看到的是一堆终端装饰（`[thinking]`、ANSI、进度行），失败时还得靠正则猜
 * 「哪一行像错误」。`cline --json` 把同一场运行拆成结构化事件，终稿、错误、用量
 * 都有明确字段，正好用来做「结果可读 + 失败原因准确」。
 *
 * 实测 3.0.74 的事件形状（完整样本见 docs/bridge-notes.md）：
 *
 *   {"ts","type":"hook_event","hookEventName":"agent_start","agentId":"agent_…","taskId":"conv_…"}
 *   {"ts","type":"agent_event","event":{"type":"iteration_start","iteration":1}}
 *   {"ts","type":"agent_event","event":{"type":"usage","inputTokens":…,"outputTokens":…,"totalCost":…}}
 *   {"ts","type":"agent_event","event":{"type":"done","reason":"completed","text":"OK","usage":{…}}}
 *   {"ts","type":"run_result","finishReason":"completed","text":"OK","usage":{…},"model":{"id":"…","provider":"…"}}
 *   {"ts","type":"error","message":"Authentication Fails (governor)"}   ← 也可能只在 stderr
 *
 * 注意：`taskId` 是 `conv_…`，**不是** `~/.cline/data/sessions/<id>` 的会话 ID
 * （实测两者时间戳都不一样，sessions.db 的 conversation_id 也是 null）。
 * 所以会话配对仍然靠会话目录扫描，别拿 taskId 当 sessionId 用。
 *
 * 解析是增量的：数据块可能在任意位置截断一行，未闭合的半行留到下次 push 再拼。
 * 只保留需要的字段，不把整条事件流堆在内存里（长回复的事件可以有几千条）。
 */

/** 终稿文本上限，与 command-worker 的 RESULT_LIMIT 保持一致。 */
const DEFAULT_MAX_TEXT = 20000

/** 出现这些 finishReason 就算失败，即使 CLI 以 0 退出。 */
const FAILURE_REASONS = new Set(['error', 'failed', 'aborted', 'cancelled'])

function toText(value) {
  return typeof value === 'string' ? value : ''
}

/**
 * 单行解析（纯函数，便于测试）。
 * 返回 null 表示这行不是 JSON（例如 CLI 的告警行），调用方只计数、不报错。
 */
export function parseClineJsonLine(line) {
  const text = String(line ?? '').trim()
  if (!text.startsWith('{') || !text.endsWith('}')) return null
  try {
    const value = JSON.parse(text)
    return value && typeof value === 'object' ? value : null
  } catch {
    return null
  }
}

export function createClineJsonParser({ maxTextChars = DEFAULT_MAX_TEXT } = {}) {
  const limit = Number.isFinite(Number(maxTextChars)) && Number(maxTextChars) > 0
    ? Number(maxTextChars)
    : DEFAULT_MAX_TEXT

  const state = {
    sawJson: false,
    jsonLines: 0,
    otherLines: 0,
    taskId: null,
    agentId: null,
    finishReason: null,
    errorMessage: null,
    errorClass: null,
    usage: null,
    model: null,
    provider: null,
    durationMs: null,
    toolCalls: null,
    iterations: null,
    runText: '',
    doneText: '',
    textTruncated: false
  }

  /** 未闭合的半行（chunk 边界）。 */
  let pending = ''

  function clip(value) {
    const text = toText(value)
    if (text.length <= limit) return text
    state.textTruncated = true
    // 保留开头：终稿一般把结论写在前面，后文是解释。
    return text.slice(0, limit)
  }

  function applyUsage(usage) {
    if (!usage || typeof usage !== 'object') return
    state.usage = {
      inputTokens: Number(usage.inputTokens) || 0,
      outputTokens: Number(usage.outputTokens) || 0,
      totalCost: Number(usage.totalCost) || 0
    }
  }

  function handle(obj) {
    const type = obj?.type

    if (type === 'hook_event') {
      if (obj.hookEventName === 'agent_start') {
        if (obj.taskId) state.taskId = String(obj.taskId)
        if (obj.agentId) state.agentId = String(obj.agentId)
      }
      return
    }

    // stderr 上的致命错误：{"ts","type":"error","message":"…"}
    if (type === 'error') {
      if (obj.message) state.errorMessage = String(obj.message)
      return
    }

    if (type === 'run_result') {
      if (typeof obj.text === 'string') state.runText = clip(obj.text)
      if (obj.finishReason) state.finishReason = String(obj.finishReason)
      if (Number.isFinite(Number(obj.durationMs))) state.durationMs = Number(obj.durationMs)
      applyUsage(obj.aggregateUsage ?? obj.usage)
      if (obj.model && typeof obj.model === 'object') {
        if (obj.model.id) state.model = String(obj.model.id)
        if (obj.model.provider) state.provider = String(obj.model.provider)
      }
      return
    }

    if (type === 'agent_event' && obj.event && typeof obj.event === 'object') {
      const event = obj.event
      if (event.type === 'done') {
        if (typeof event.text === 'string') state.doneText = clip(event.text)
        // run_result 才是最终结论；done 只做兜底。
        if (!state.finishReason && event.reason) state.finishReason = String(event.reason)
        if (Number.isFinite(Number(event.iterations))) state.iterations = Number(event.iterations)
        applyUsage(event.usage)
      } else if (event.type === 'error') {
        const message = event.error?.message ?? event.message
        if (message) state.errorMessage = String(message)
        if (event.errorClass) state.errorClass = String(event.errorClass)
        if (!state.finishReason) state.finishReason = 'error'
      } else if (event.type === 'iteration_end' && Number.isFinite(Number(event.toolCallCount))) {
        state.toolCalls = (state.toolCalls ?? 0) + Number(event.toolCallCount)
      }
    }
  }

  function push(chunk) {
    if (chunk === undefined || chunk === null) return
    pending += typeof chunk === 'string' ? chunk : String(chunk)

    let index = pending.indexOf('\n')
    while (index >= 0) {
      const line = pending.slice(0, index)
      pending = pending.slice(index + 1)
      const obj = parseClineJsonLine(line)
      if (obj) {
        state.sawJson = true
        state.jsonLines += 1
        handle(obj)
      } else if (line.trim()) {
        state.otherLines += 1
      }
      index = pending.indexOf('\n')
    }

    // 防御：没有任何换行的超长输出（或 CLI 卡住吐日志）别把内存吃满。
    if (pending.length > limit * 4) {
      pending = pending.slice(-limit * 2)
      state.otherLines += 1
    }
  }

  /** 收尾：flush 最后一行（CLI 可能不输出结尾换行）。 */
  function end() {
    if (pending.trim()) {
      const obj = parseClineJsonLine(pending)
      if (obj) {
        state.sawJson = true
        state.jsonLines += 1
        handle(obj)
      } else {
        state.otherLines += 1
      }
    }
    pending = ''
    return snapshot()
  }

  function snapshot() {
    return {
      sawJson: state.sawJson,
      jsonLines: state.jsonLines,
      otherLines: state.otherLines,
      taskId: state.taskId,
      agentId: state.agentId,
      /** 终稿：run_result.text 优先，其次 agent_event.done.text。 */
      text: state.runText || state.doneText || '',
      finishReason: state.finishReason,
      errorMessage: state.errorMessage,
      errorClass: state.errorClass,
      usage: state.usage,
      model: state.model,
      provider: state.provider,
      durationMs: state.durationMs,
      toolCalls: state.toolCalls,
      iterations: state.iterations,
      textTruncated: state.textTruncated
    }
  }

  return { push, end, snapshot }
}

/**
 * JSON 事件说这次运行失败了吗？
 *
 * 为什么不能只看 exit code：实测认证失败时事件里是
 * `{"event":{"type":"error","errorClass":"auth"}}` + stderr 的 `{"type":"error",…}`，
 * 而 CLI 的退出码并不可靠（不同版本对「一轮结束但没产出」的处理不一样）。
 * 有明确 finishReason 就按它判断；只有 error、没有终稿时也算失败。
 */
export function isClineJsonFailure(json) {
  if (!json?.sawJson) return false
  const reason = String(json.finishReason ?? '').toLowerCase()
  if (FAILURE_REASONS.has(reason)) return true
  return Boolean(json.errorMessage) && !json.text
}

