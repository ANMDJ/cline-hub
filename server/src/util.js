import { HttpError } from './http.js'

export function requireString(value, field, { max = 4000, min = 1 } = {}) {
  if (typeof value !== 'string') throw new HttpError(400, `${field} must be a string`, 'invalid_field')
  const trimmed = value.trim()
  if (trimmed.length < min) throw new HttpError(400, `${field} is required`, 'invalid_field')
  if (trimmed.length > max) throw new HttpError(400, `${field} longer than ${max} chars`, 'invalid_field')
  return trimmed
}

export function optionalString(value, field, max = 4000) {
  if (value === undefined || value === null) return null
  if (typeof value !== 'string') throw new HttpError(400, `${field} must be a string`, 'invalid_field')
  const trimmed = value.trim()
  if (!trimmed) return null
  return trimmed.length > max ? trimmed.slice(0, max) : trimmed
}

/**
 * 统一文件系统路径的写法。
 *
 * Windows 上同一个目录可能被写成 `C:\a\b` 或 `C:/a/b`：cline CLI 落库用正斜杠，
 * 人手填的白名单 / 命令参数用反斜杠。两者在库里是不同的字符串，App 按路径分组
 * 就会把同一个项目拆成两组（2026-11-02 实测：`...\cline-hub` 31 条 + `.../cline-hub` 1 条）。
 *
 * 规则只抹平「同一个目录的不同写法」，**不动大小写**（Linux 路径大小写敏感）：
 *   * `C:/a/b`、`C:\\a\\b`、`C:\a\b\` → `C:\a\b`
 *   * `\\server\share\` → `\\server\share`（UNC 的两个前导反斜杠保留）
 *   * `/home/me/app` 原样返回（POSIX 路径没有分隔符歧义）
 *   * 相对名（`kids_points_app`）原样返回
 */
export function normalizeFsPath(value) {
  if (typeof value !== 'string') return value
  const raw = value.trim()
  if (!raw) return raw
  const windows = /^[a-zA-Z]:[\\/]/.test(raw) || raw.startsWith('\\\\')
  if (!windows) return raw

  const unc = raw.startsWith('\\\\')
  const body = (unc ? raw.slice(2) : raw)
    .replace(/\//g, '\\')
    .replace(/\\{2,}/g, '\\')
    .replace(/\\+$/, '')
  // 盘符根 `C:\` 不能去掉反斜杠：`C:` 的语义是「盘符当前目录」
  const normalized = /^[a-zA-Z]:$/.test(body) ? `${body}\\` : body
  return (unc ? '\\\\' : '') + normalized
}

export function intOrNull(value) {
  if (value === undefined || value === null || value === '') return null
  const num = Number(value)
  return Number.isInteger(num) ? num : null
}

/** Accepts ISO strings or epoch-millis numbers; anything else becomes null. */
export function isoOrNull(value) {
  if (value === undefined || value === null || value === '') return null
  const date = typeof value === 'number' ? new Date(value) : new Date(String(value))
  return Number.isNaN(date.getTime()) ? null : date.toISOString()
}

export function boolOrFalse(value) {
  return value === true
}

export function limitFrom(url, fallback = 50, max = 200) {
  const raw = Number(url.searchParams.get('limit') ?? '')
  if (!Number.isInteger(raw) || raw <= 0) return fallback
  return Math.min(raw, max)
}

/**
 * A device token may only write its own rows; the admin token may act on any
 * device (used by curl/scripts during setup).
 */
export function resolveDeviceId(client, source) {
  const requested = typeof source?.deviceId === 'string' ? source.deviceId.trim() : ''
  if (client.role === 'admin') {
    if (!requested) throw new HttpError(400, 'deviceId is required for admin calls', 'invalid_field')
    return requested
  }
  if (client.role !== 'device') throw new HttpError(403, 'only a device token can write here', 'forbidden')
  if (requested && requested !== client.id) {
    throw new HttpError(403, `token belongs to ${client.id}, not ${requested}`, 'device_mismatch')
  }
  return client.id
}

/**
 * 读接口的设备范围（多设备隔离，ADR-43）。
 *
 * 写接口用 `resolveDeviceId()`（device 必须写自己），读接口的规则不同：
 *   * `device`：只能读自己的行；显式传别人的 `deviceId` 直接 403，
 *     和写接口的 `device_mismatch` 语义保持一致（不静默忽略，客户端能尽早发现接错 token）；
 *   * `app` / `admin`：不传 = 读全部；传了 = 只看那台设备。
 *
 * 返回值直接用作 SQL 的可选过滤值（null = 不加条件）。
 */
export function readDeviceScope(client, requested) {
  const value = typeof requested === 'string' ? requested.trim() : ''
  if (!client) throw new HttpError(401, 'missing or invalid token', 'unauthorized')
  if (client.role === 'device') {
    if (value && value !== client.id) {
      throw new HttpError(403, `token belongs to ${client.id}, not ${value}`, 'device_mismatch')
    }
    return client.id
  }
  return value || null
}

export function toJsonArray(value) {
  if (Array.isArray(value)) return value
  return []
}

export function toJsonObject(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : {}
}

export const nowIso = () => new Date().toISOString()
