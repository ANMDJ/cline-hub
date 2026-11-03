import fs from 'node:fs'
import path from 'node:path'

/**
 * 附件下载与 prompt 拼装（P38）。
 *
 * 手机端发文件 / 图片时，命令里只有附件元数据（`command.attachment`），
 * 内容要 bridge 自己用 device token 拉回来：
 *
 *   Hub `GET /api/v1/attachments/<id>` → 写进本机临时目录 → 把**绝对路径**
 *   拼进 prompt，cline 才能真的读到这个文件。
 *
 * 为什么不把内容塞进 prompt：base64 会撑爆 prompt 长度上限（Hub 4000 字），
 * 而且模型读二进制没有意义；给路径 + 一句「先读这个文件」才是 CLI 愿意配合的写法。
 */

/** 单份附件上限，比 Hub 默认（8 MB）宽松一档，避免两侧默认值不一致时互相打架。 */
export const MAX_ATTACHMENT_BYTES = 16 * 1024 * 1024

/** Windows 保留设备名：`con.txt` 这种落盘会直接失败。 */
const WINDOWS_RESERVED = /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$/i

/**
 * 落盘用的文件名：只留基名，去掉 Windows 不接受的字符。
 * commandId 会作为前缀，所以同名附件并发跑也不会互相覆盖。
 */
export function safeFileName(name, fallback = 'attachment') {
  const base = String(name ?? '').split(/[\\/]/).pop() ?? ''
  const cleaned = base
    .replace(/[\u0000-\u001f<>:"|?*]/g, '_')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/^\.+/, '')
    .slice(0, 100)
  if (!cleaned) return fallback
  return WINDOWS_RESERVED.test(cleaned) ? `_${cleaned}` : cleaned
}

/** 1.2 MB / 480 KB：手机上看得懂的大小。 */
export function formatBytes(size) {
  const value = Number(size)
  if (!Number.isFinite(value) || value <= 0) return '0 B'
  const units = ['B', 'KB', 'MB', 'GB']
  let scaled = value
  let unit = 0
  while (scaled >= 1024 && unit < units.length - 1) {
    scaled /= 1024
    unit += 1
  }
  const digits = unit === 0 ? 0 : scaled >= 100 ? 0 : 1
  return `${scaled.toFixed(digits)} ${units[unit]}`
}

/**
 * prompt = 用户写的那句话 + 「文件已经在这台电脑的哪个位置」。
 *
 * 用户没写任何说明时（只发文件）也要给模型一句明确指令，否则它可能把
 * 路径当成要执行的命令，或者干脆忽略附件。
 */
export function composePrompt({ caption, filePath, name, mimeType, byteSize }) {
  const text = String(caption ?? '').trim()
  const detail = [
    `  路径：${filePath}`,
    `  原名：${name}`,
    mimeType
      ? `  类型：${mimeType}（${formatBytes(byteSize)}）`
      : `  大小：${formatBytes(byteSize)}`
  ].join('\n')
  const instruction = text
    ? '请先读取这个文件，再按上面的要求处理。'
    : '请先读取这个文件，简要说明它是什么内容；我没有别的说明，先不要修改任何文件。'
  return `${text ? `${text}\n\n` : ''}[附件] 手机端发来的文件已保存到这台电脑上：\n${detail}\n${instruction}`
}

/**
 * 下载附件并落盘，返回 prompt 里要用的绝对路径。
 *
 * 失败一律抛错（HTTP 状态 / 空文件 / 超限），由 command-worker 回写 `failed`：
 * 「附件没到手还继续跑」比直接失败更难排查。
 */
export async function saveAttachment({
  hubUrl,
  token,
  attachment,
  dir,
  commandId,
  maxBytes = MAX_ATTACHMENT_BYTES,
  timeoutMs = 60000,
  fetchImpl = fetch
}) {
  const id = String(attachment?.id ?? '').trim()
  if (!id) throw new Error('附件缺少 id')
  const base = String(hubUrl ?? '').replace(/\/+$/, '')
  if (!base) throw new Error('hubUrl 未配置，下载不了附件')

  const url = `${base}/api/v1/attachments/${encodeURIComponent(id)}`
  const response = await fetchImpl(url, {
    headers: token ? { authorization: `Bearer ${token}` } : {},
    signal: AbortSignal.timeout(timeoutMs)
  })
  if (!response.ok) {
    const detail = await response.text().catch(() => '')
    throw new Error(`GET ${url} -> ${response.status} ${String(detail).slice(0, 200)}`)
  }

  const buffer = Buffer.from(await response.arrayBuffer())
  if (buffer.length === 0) throw new Error('附件是空的（0 字节）')
  if (buffer.length > maxBytes) {
    throw new Error(`附件超过 ${formatBytes(maxBytes)}（实际 ${formatBytes(buffer.length)}）`)
  }

  fs.mkdirSync(dir, { recursive: true })
  const name = safeFileName(attachment?.name)
  const filePath = path.join(dir, `${commandId}-${name}`)
  fs.writeFileSync(filePath, buffer)

  return {
    filePath,
    name,
    mimeType: attachment?.mimeType ? String(attachment.mimeType) : null,
    byteSize: buffer.length
  }
}
