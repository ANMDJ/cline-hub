/**
 * 网络小工具：真实调用方 IP、CIDR 白名单、令牌桶限流。
 *
 * Hub 只监听 127.0.0.1，前面永远是本机 Caddy，所以 socket 地址恒为回环；
 * 真实 IP 取 `X-Forwarded-For` 的**最后一段**（仅当直连方是回环时才信任它）。
 * 无第三方依赖，方便容器里跑。
 *
 * 为什么是最后一段（ADR-63）：XFF 是「客户端 → 每一跳代理依次追加」的列表，
 * 最左边那段是请求方自己写进来的，可以随便伪造；最右边那段才是紧邻我们的
 * 代理（Caddy）看到并追加的真实对端地址。取第一段等于把攻击者可控的字符串
 * 当成 IP，`HUB_ALLOW_IPS` 与限流会被一起绕过（2026-11-04 前的实现就是取第一段）。
 */

const IPV4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/

export function normalizeIp(raw) {
  const value = String(raw ?? '').trim()
  if (!value) return ''
  return value.startsWith('::ffff:') ? value.slice(7) : value
}

export function isLoopback(ip) {
  return ip === '127.0.0.1' || ip === '::1' || ip.startsWith('127.')
}

export function clientIp(req) {
  const direct = normalizeIp(req.socket?.remoteAddress)
  if (!isLoopback(direct)) return direct // 直连（本机 smoke / 容器内）就是它自己
  const forwarded = String(req.headers['x-forwarded-for'] ?? '')
  const segments = forwarded
    .split(',')
    .map((part) => part.trim())
    .filter(Boolean)
  if (segments.length === 0) return direct
  // 取最后一段：紧邻我们的代理追加的那一跳。首段是调用方自带的，不可信。
  return normalizeIp(segments[segments.length - 1]) || direct
}

function ipv4ToInt(ip) {
  const match = IPV4.exec(ip)
  if (!match) return null
  const parts = match.slice(1).map(Number)
  if (parts.some((n) => n < 0 || n > 255)) return null
  return (((parts[0] << 24) >>> 0) + (parts[1] << 16) + (parts[2] << 8) + parts[3]) >>> 0
}

/** 规则是单 IP 或 IPv4 CIDR（`10.0.0.0/8`）；IPv6 只做精确比较。 */
export function ipMatches(ip, rule) {
  const target = normalizeIp(rule)
  if (!target || !ip) return false
  if (!target.includes('/')) return ip === target

  const [base, bitsRaw] = target.split('/')
  const bits = Number(bitsRaw)
  if (!Number.isInteger(bits) || bits < 0 || bits > 32) return false
  const baseInt = ipv4ToInt(base)
  const ipInt = ipv4ToInt(ip)
  if (baseInt === null || ipInt === null) return false
  if (bits === 0) return true
  const mask = (0xffffffff << (32 - bits)) >>> 0
  return ((baseInt & mask) >>> 0) === ((ipInt & mask) >>> 0)
}

/** 空规则表 = 不限制（默认）。 */
export function ipAllowed(ip, rules) {
  if (!rules || rules.length === 0) return true
  return rules.some((rule) => ipMatches(ip, rule))
}

/**
 * 每 IP 令牌桶：允许 `burst` 个瞬时请求，之后按 `perSec` 恢复。
 * 只做进程内计数（单实例部署足够），不会因为 Map 膨胀而泄漏内存。
 */
export function createRateLimiter({ perSec = 5, burst = 120, sweepMs = 60_000 } = {}) {
  const buckets = new Map()
  const rate = Number.isFinite(perSec) && perSec > 0 ? perSec : 5
  const capacity = Number.isFinite(burst) && burst >= 1 ? burst : 120

  const timer = setInterval(() => {
    const now = Date.now()
    for (const [ip, bucket] of buckets) {
      if (now - bucket.at > sweepMs) buckets.delete(ip)
    }
  }, sweepMs)
  timer.unref?.()

  return function take(ip) {
    const now = Date.now()
    const bucket = buckets.get(ip) ?? { tokens: capacity, at: now }
    bucket.tokens = Math.min(capacity, bucket.tokens + ((now - bucket.at) / 1000) * rate)
    bucket.at = now
    if (bucket.tokens < 1) {
      buckets.set(ip, bucket)
      return false
    }
    bucket.tokens -= 1
    buckets.set(ip, bucket)
    return true
  }
}
