import { HttpError } from '../http.js'

/**
 * DeepSeek 账户余额代理（P44）。
 *
 * 为什么由 Hub 转发，而不是让 App 直接调 api.deepseek.com：
 *
 * 1. API Key 只落一份，放在 `server/.env`（已 gitignore），不会进 APK / 手机存储；
 * 2. 手机在弱网、切后台时不该为一次余额查询等十几秒，Hub 可以缓存 + 复用同一个上游请求；
 * 3. DeepSeek 的余额接口没有 CORS 保证，Web 预览（`flutter run -d chrome`）直连会被浏览器拦掉。
 *
 * 上游契约：`GET https://api.deepseek.com/user/balance`
 * → `{ is_available, balance_infos: [{ currency, total_balance, granted_balance, topped_up_balance }] }`
 * 字段都是字符串金额（如 `"110.00"`），这里原样透传，不在服务端做浮点运算。
 */

const BALANCE_PATH = '/user/balance'

/** 上游金额：字符串原样保留，数字就转字符串；缺失时给 `null`。 */
function amount(value) {
  if (typeof value === 'string') return value.trim()
  if (typeof value === 'number' && Number.isFinite(value)) return value.toFixed(2)
  return null
}

function normalizeBalances(raw) {
  if (!Array.isArray(raw)) return []
  return raw
    .filter((item) => item && typeof item === 'object')
    .map((item) => ({
      currency: String(item.currency ?? '').trim().toUpperCase(),
      totalBalance: amount(item.total_balance),
      grantedBalance: amount(item.granted_balance),
      toppedUpBalance: amount(item.topped_up_balance)
    }))
    .filter((item) => item.currency !== '')
}

/**
 * 把上游 / 网络的失败翻译成 App 能看懂的错误码。
 *
 * 401 / 403 不能原样透传状态码：那会让手机端以为是自己的 Hub token 失效
 * （`ApiException.isAuth` 会直接把链路标成 offline）。统一用 502 + 明确的 code。
 */
function upstreamError(status, body) {
  if (status === 401 || status === 403) {
    return new HttpError(502, 'DeepSeek rejected the API key (401/403)', 'deepseek_auth_failed')
  }
  if (status === 429) {
    return new HttpError(502, 'DeepSeek rate limited the balance request (429)', 'deepseek_rate_limited')
  }
  const detail = typeof body === 'string' && body.trim() !== '' ? body.trim().slice(0, 200) : ''
  return new HttpError(
    502,
    `DeepSeek balance request failed (${status})${detail ? `: ${detail}` : ''}`,
    'deepseek_error'
  )
}

export function createDeepSeekRoutes({ logger, config, fetchImpl }) {
  const doFetch = fetchImpl ?? globalThis.fetch
  const ttlMs = Math.max(1, config.deepseekBalanceTtlSec ?? 60) * 1000
  const timeoutMs = Math.max(1000, config.deepseekTimeoutMs ?? 8000)
  const baseUrl = String(config.deepseekBaseUrl || 'https://api.deepseek.com').replace(/\/+$/, '')
  const apiKey = String(config.deepseekApiKey ?? '').trim()

  /** 最近一次成功的结果：短缓存 + 上游抖动时的兜底。进程内，不落库。 */
  let cache = null
  /** 同一时刻只打一次上游：手机端「下拉刷新 + 定时刷新」撞在一起时不放大请求。 */
  let inflight = null

  async function fetchFromUpstream() {
    const startedAt = Date.now()
    let response
    try {
      response = await doFetch(`${baseUrl}${BALANCE_PATH}`, {
        method: 'GET',
        headers: { accept: 'application/json', authorization: `Bearer ${apiKey}` },
        signal: AbortSignal.timeout(timeoutMs)
      })
    } catch (error) {
      if (error?.name === 'TimeoutError' || error?.name === 'AbortError') {
        throw new HttpError(504, `DeepSeek balance request timed out after ${timeoutMs}ms`, 'deepseek_timeout')
      }
      throw new HttpError(503, `cannot reach DeepSeek: ${error?.message ?? error}`, 'deepseek_unreachable')
    }

    const text = await response.text().catch(() => '')
    let body = null
    try {
      body = text.trim() === '' ? null : JSON.parse(text)
    } catch {
      body = null
    }

    if (!response.ok) throw upstreamError(response.status, text)
    if (!body || typeof body !== 'object') {
      throw new HttpError(502, 'DeepSeek returned a non-JSON balance payload', 'deepseek_bad_response')
    }

    const payload = {
      ok: true,
      configured: true,
      isAvailable: body.is_available !== false,
      balances: normalizeBalances(body.balance_infos),
      fetchedAt: new Date().toISOString(),
      latencyMs: Date.now() - startedAt,
      cached: false
    }
    cache = { payload, at: Date.now() }
    return payload
  }

  async function load() {
    if (inflight) return inflight
    inflight = fetchFromUpstream().finally(() => {
      inflight = null
    })
    return inflight
  }

  return [
    {
      method: 'GET',
      pattern: '/api/v1/deepseek/balance',
      auth: 'app',
      async handler({ url }) {
        if (!apiKey) {
          // 未配置不是错误：App 要能区分「没配 key」和「查询失败」，
          // 所以 200 + configured:false，让卡片显示配置提示而不是红字报错。
          return {
            ok: true,
            configured: false,
            isAvailable: false,
            balances: [],
            fetchedAt: null,
            cached: false,
            hint: '在 Hub 的 server/.env 里配置 DEEPSEEK_API_KEY 后重启容器'
          }
        }

        const force = url?.searchParams?.get('refresh') === '1'
        if (!force && cache && Date.now() - cache.at < ttlMs) {
          return { ...cache.payload, cached: true, ageMs: Date.now() - cache.at }
        }

        try {
          return await load()
        } catch (error) {
          // 有旧数据就端旧数据：余额不是交易凭证，展示 5 分钟前的数字
          // 比整块变红更有用；`stale: true` 让 App 明确标注。
          if (cache) {
            logger.warn('deepseek balance refresh failed, serving stale', {
              code: error?.code ?? null,
              message: error?.message ?? String(error),
              ageMs: Date.now() - cache.at
            })
            return {
              ...cache.payload,
              cached: true,
              stale: true,
              ageMs: Date.now() - cache.at,
              warning: error?.message ?? String(error)
            }
          }
          logger.warn('deepseek balance lookup failed', {
            code: error?.code ?? null,
            message: error?.message ?? String(error)
          })
          throw error
        }
      }
    }
  ]
}
