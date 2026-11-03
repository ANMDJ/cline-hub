import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

export const serverRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')

/** Tiny .env reader: KEY=VALUE, # comments, optional surrounding quotes. */
function parseEnvFile(file) {
  const out = {}
  if (!fs.existsSync(file)) return out
  for (const rawLine of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const line = rawLine.trim()
    if (!line || line.startsWith('#')) continue
    const eq = line.indexOf('=')
    if (eq === -1) continue
    const key = line.slice(0, eq).trim()
    let value = line.slice(eq + 1).trim()
    const quoted =
      (value.startsWith('"') && value.endsWith('"') && value.length >= 2) ||
      (value.startsWith("'") && value.endsWith("'") && value.length >= 2)
    if (quoted) value = value.slice(1, -1)
    if (key) out[key] = value
  }
  return out
}

const fileEnv = parseEnvFile(path.join(serverRoot, '.env'))
const read = (key, fallback = '') => process.env[key] ?? fileEnv[key] ?? fallback
const readInt = (key, fallback) => {
  const value = Number(read(key, ''))
  return Number.isInteger(value) && value > 0 ? value : fallback
}

export const config = {
  serverRoot,
  host: read('HUB_HOST', '127.0.0.1'),
  port: readInt('HUB_PORT', 3100),
  databaseUrl: read('HUB_DATABASE_URL', ''),
  adminToken: read('HUB_ADMIN_TOKEN', ''),
  autoMigrate: read('HUB_AUTO_MIGRATE', '1') !== '0',
  logLevel: read('HUB_LOG_LEVEL', 'info'),
  logFile: read('HUB_LOG_FILE', ''),
  corsOrigin: read('HUB_CORS_ORIGIN', '*'),
  maxBodyBytes: readInt('HUB_MAX_BODY_BYTES', 4 * 1024 * 1024),
  /**
   * 单份附件（手机发文件 / 图片）的大小上限。
   * 只影响 `POST /api/v1/attachments` 这一条路由（base64 后体积 ≈ 4/3），
   * 其余接口仍然是 `maxBodyBytes`，不会因为发大图就放宽全站。
   */
  maxAttachmentBytes: readInt('HUB_MAX_ATTACHMENT_BYTES', 8 * 1024 * 1024),
  sseHeartbeatMs: readInt('HUB_SSE_HEARTBEAT_MS', 25000),
  // 兜底防护：每 IP 令牌桶 + 可选 CIDR 白名单（白名单为空 = 不限 IP）
  rateLimitPerSec: readInt('HUB_RATE_LIMIT_PER_SEC', 5),
  rateLimitBurst: readInt('HUB_RATE_LIMIT_BURST', 120),
  allowIps: read('HUB_ALLOW_IPS', '')
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean),
  version: '0.1.0'
}
