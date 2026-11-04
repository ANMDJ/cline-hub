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
  /**
   * SSE 短期票据（P41）：App 先 `POST /api/v1/sse-ticket` 换票，再用 `?ticket=` 连。
   * 60 秒足够「拿到票 → 建连」，过期就再换一张（重连本来就会走一次）。
   */
  sseTicketTtlSec: readInt('HUB_SSE_TICKET_TTL_SEC', 60),
  /**
   * SSE 纵深防御（P43）：单 token 连接上限 + 空闲超时。
   * 上限只管「同一个 client 反复重连堆连接」；不同设备互不影响。
   */
  sseMaxPerClient: readInt('HUB_SSE_MAX_CONNECTIONS', 8),
  sseIdleTimeoutMs: readInt('HUB_SSE_IDLE_TIMEOUT_SEC', 600) * 1000,
  /**
   * SSE 的 Origin 白名单（P43）：留空 = 只放行「不带 Origin」或「同源」的请求。
   * 以后真要接浏览器端，把它的 origin（如 `https://hub.example.com`）加进来。
   */
  sseAllowedOrigins: read('HUB_SSE_ALLOWED_ORIGINS', '')
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean),
  /**
   * 命令租约（P42）：bridge 认领后必须在这个时间内续租，否则 Hub 判定执行侧失联。
   * 120 秒 = 默认 30 秒心跳的 4 倍，允许丢一两次请求；扫描间隔 60 秒。
   * 这两个值只影响「多久把失联命令收成 failed」，不影响真正在跑的命令
   * （只要 bridge 活着就会持续续租）。
   */
  commandLeaseSec: readInt('HUB_COMMAND_LEASE_SEC', 120),
  commandLeaseSweepMs: readInt('HUB_COMMAND_LEASE_SWEEP_SEC', 60) * 1000,
  /**
   * DeepSeek 余额（P44）：Key 只配在 Hub 上，App 永远看不到明文。
   * 留空时 `/api/v1/deepseek/balance` 返回 `configured:false`，App 显示配置提示。
   */
  deepseekApiKey: read('DEEPSEEK_API_KEY', ''),
  deepseekBaseUrl: read('DEEPSEEK_BASE_URL', 'https://api.deepseek.com'),
  /** 余额短缓存：默认 60 秒，手机连点刷新也不会把上游打爆。 */
  deepseekBalanceTtlSec: readInt('DEEPSEEK_BALANCE_TTL_SEC', 60),
  deepseekTimeoutMs: readInt('DEEPSEEK_TIMEOUT_MS', 8000),
  // 兜底防护：每 IP 令牌桶 + 可选 CIDR 白名单（白名单为空 = 不限 IP）
  rateLimitPerSec: readInt('HUB_RATE_LIMIT_PER_SEC', 5),
  rateLimitBurst: readInt('HUB_RATE_LIMIT_BURST', 120),
  allowIps: read('HUB_ALLOW_IPS', '')
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean),
  version: '0.1.0'
}
