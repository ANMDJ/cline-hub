/**
 * 列表预览的「纯文本化」。
 *
 * `sessions.result_text` 是模型原始输出：Markdown（`##`、```、`**`、表格）叠上
 * 终端控制序列。手机上直接把前 400 字塞进卡片，看到的就是「乱码」。
 *
 * 为什么在服务端洗，而不是客户端：
 * - 预览是派生数据，App / Web / 以后的通知都该看到同一份；
 * - 客户端只拿到 400 字，如果这 400 字全是 ``` 和 `##`，再洗也洗不出正文，
 *   必须先取更长的原文（PREVIEW_SOURCE_CHARS）再截断。
 *
 * 命令输出（`commands.result_text`）不走这里：那是终端回放，App 用
 * `stripAnsi()` 只做展示层过滤，库里保留原始字节（以后可能做富渲染）。
 */

/** 预览对外长度（`docs/api.md` 的 400 字契约）。 */
export const PREVIEW_CHARS = 400

/** 列表 SQL 先取这么长的原文：Markdown/ANSI 去掉后仍然够 400 字。 */
export const PREVIEW_SOURCE_CHARS = 2000

const ANSI = new RegExp(
  [
    '\\u001b\\][\\s\\S]*?(?:\\u0007|\\u001b\\\\)', // OSC：窗口标题、超链接
    '\\u001b[PX^_][\\s\\S]*?\\u001b\\\\', // DCS / SOS / PM / APC
    '\\u001b\\[[0-?]*[ -/]*[@-~]', // CSI：颜色、光标移动
    '\\u001b[@-Z\\\\-_]' // 两字符转义
  ].join('|'),
  'g'
)

/** 被截断后剩下的半个 CSI（`ESC [`）或落单的 ESC。 */
const PARTIAL_CSI = /\u001b\[[0-?]*[ -/]*/g
const LONE_ESC = /\u001b/g

/** 被截断后留下的半个序列（`[2m` 这种没有 ESC 的尾巴）。 */
const ORPHAN_SGR = /(^|\s)\[[0-9]{1,3}(?:;[0-9]{1,3}){0,4}m/g

/** 除 \n \t 之外的 C0 控制字符与 DEL。 */
const CONTROL = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g

const TABLE_SEPARATOR = /^\s*\|?[\s:|-]*-[\s:|-]*\|?\s*$/gm
const LIST_MARKER = /^\s*(?:[-*+]|\d{1,3}[.)])\s+(?:\[[ xX]\]\s+)?/gm
const HEADING = /^\s{0,3}#{1,6}\s+/gm
const QUOTE = /^\s{0,3}>\s?/gm
const FENCE = /^\s*(?:```|~~~)[^\n]*$/gm
const RULE = /^\s*(?:[-*_]\s*){3,}$/gm
const LINK = /!?\[([^\]]*)\]\([^)]*\)/g
const BOLD = /\*\*(?=[^\s*])([^*\n]*?[^\s*])\*\*/g
const UNDERSCORE_BOLD = /__(?=[^\s_])([^_\n]*?[^\s_])__/g
const ITALIC = /\*(?=[^\s*])([^*\n]*?[^\s*])\*/g
const STRIKE = /~~(?=\S)([^\n]*?\S)~~/g
const INLINE_CODE = /`([^`\n]*)`/g
const INLINE_TAG =
  /<\/?(?:br|p|div|span|b|i|strong|em|code|pre|a|img|ul|ol|li|h[1-6]|hr|table|thead|tbody|tr|td|th)\b[^>]*>/gi

/** 去掉终端控制序列（SGR 颜色、光标、OSC 标题等）。 */
export function stripAnsi(text) {
  if (typeof text !== 'string' || !text) return ''
  return text
    .replace(ANSI, '')
    .replace(PARTIAL_CSI, '')
    .replace(LONE_ESC, '')
    .replace(ORPHAN_SGR, '$1')
    .replace(CONTROL, '')
}

/**
 * 表格行 `| a | b |` → `a b`：只在整行以 `|` 开头时处理，
 * 免得把正文里的 shell 管道（`ls | grep`）也改掉。
 */
function unwrapTableRows(text) {
  if (!text.includes('|')) return text
  return text
    .split('\n')
    .map((line) =>
      /^\s*\|/.test(line)
        ? line.replace(/^\s*\|/, '').replace(/\|\s*$/, '').replace(/\s*\|\s*/g, ' ')
        : line
    )
    .join('\n')
}

/** 去掉 Markdown 记号，保留文字本身（代码块内容也保留）。 */
export function stripMarkdown(text) {
  if (typeof text !== 'string' || !text) return ''
  return unwrapTableRows(
    text
      .replace(/<!--[\s\S]*?-->/g, ' ')
      .replace(FENCE, '\n')
      .replace(LINK, '$1')
      .replace(HEADING, '')
      .replace(QUOTE, '')
      .replace(TABLE_SEPARATOR, ' ')
      .replace(RULE, ' ')
      .replace(LIST_MARKER, '')
      .replace(BOLD, '$1')
      .replace(UNDERSCORE_BOLD, '$1')
      .replace(ITALIC, '$1')
      .replace(STRIKE, '$1')
      .replace(INLINE_CODE, '$1')
      .replace(INLINE_TAG, ' ')
  )
}

/** 多行折成一行：预览是卡片里的一句话，换行没有意义。 */
export function collapseWhitespace(text) {
  if (typeof text !== 'string' || !text) return ''
  return text.replace(/\s+/g, ' ').trim()
}

/**
 * 生成列表用的一行式预览：ANSI → Markdown → 折叠空白 → 按码点截断。
 *
 * 按码点截断（`Array.from`）是必要的：直接 `slice()` 可能把 emoji 的代理对
 * 劈成两半，客户端拿到的是半个字符（显示成 ``）。
 */
export function plainPreview(value, limit = PREVIEW_CHARS) {
  if (typeof value !== 'string') return ''
  const text = collapseWhitespace(stripMarkdown(stripAnsi(value)))
  if (!text) return ''
  const chars = Array.from(text)
  if (chars.length <= limit) return text
  return `${chars.slice(0, limit).join('').trimEnd()}…`
}
