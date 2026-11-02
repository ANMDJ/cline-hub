import http from 'node:http'

const MAX_BODY = 2 * 1024 * 1024
/** `/admin/stop` 只带一个 reason，没必要给 2MB 的额度。 */
const MAX_ADMIN_BODY = 16 * 1024

function isLoopback(address) {
  const value = String(address ?? '')
  return value === '127.0.0.1' || value === '::1' || value === '::ffff:127.0.0.1'
}

/**
 * Local-only HTTP endpoint the PowerShell hook posts to.
 * Responds 202 immediately so the hook exits fast; the payload is handed to
 * onHook afterwards (sync, cheap: it only appends to the outbox).
 *
 * 另外提供 `POST /admin/stop`：Windows 上 `Stop-Process` / `taskkill` 是直接
 * TerminateProcess，Node 收不到 SIGTERM，`shutdown()` 不会执行。要让 bridge
 * 「先回写执行中的命令、再杀进程树」，就必须有一个能触发优雅退出的入口，
 * `npm run stop` / `npm run restart` 走的就是这里（见 docs/interruptions.md）。
 */
export function startHookServer({ host = '127.0.0.1', port, onHook, onStop, logger }) {
  const server = http.createServer((req, res) => {
    const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`)

    if (req.method === 'GET' && url.pathname === '/health') {
      const body = JSON.stringify({
        ok: true,
        service: 'cline-bridge',
        now: new Date().toISOString()
      })
      res.writeHead(200, { 'content-type': 'application/json; charset=utf-8' })
      res.end(body)
      return
    }

    if (req.method === 'POST' && url.pathname === '/admin/stop') {
      // 这是「让 bridge 自杀」的开关，只认本机回环地址；局域网 / 反代打进来一律 403。
      if (!isLoopback(req.socket.remoteAddress)) {
        res.writeHead(403, { 'content-type': 'application/json' })
        res.end('{"ok":false,"error":"loopback only"}')
        return
      }

      const chunks = []
      let size = 0
      let aborted = false

      req.on('data', (chunk) => {
        if (aborted) return
        size += chunk.length
        if (size > MAX_ADMIN_BODY) {
          aborted = true
          res.writeHead(413, { 'content-type': 'application/json' })
          res.end('{"ok":false,"error":"payload too large"}')
          req.destroy()
          return
        }
        chunks.push(chunk)
      })

      req.on('end', () => {
        if (aborted) return
        let body = null
        try {
          body = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}')
        } catch {
          body = null
        }
        const reason = typeof body?.reason === 'string' && body.reason.trim()
          ? body.reason.trim().slice(0, 200)
          : 'manual stop'
        // keepChildren：从「bridge 自己拉起的会话」里重启 bridge 时用
        // （`npm run restart -- --keep-session`）。子进程就是正在跑的命令，杀掉它等于
        // 把发起这次重启的对话截断，所以这条路径只要求 bridge 自己退出。
        const keepChildren = body?.keepChildren === true
        res.writeHead(202, { 'content-type': 'application/json; charset=utf-8' })
        res.end(JSON.stringify({
          ok: true,
          stopping: true,
          reason,
          ...(keepChildren ? { keepChildren } : {})
        }))
        // 先把 202 冲出去，再交给 shutdown：它会先 PATCH 执行中的命令，再（视 keepChildren）杀进程树。
        const fire = () => {
          if (typeof onStop !== 'function') return
          try {
            onStop(reason, { keepChildren })
          } catch (error) {
            logger.error('stop handler failed', { message: error.message })
          }
        }
        if (res.writableFinished) setImmediate(fire)
        else res.once('finish', () => setImmediate(fire))
      })
      return
    }

    if (req.method === 'POST' && (url.pathname === '/hook' || url.pathname === '/')) {
      const chunks = []
      let size = 0
      let aborted = false

      req.on('data', (chunk) => {
        if (aborted) return
        size += chunk.length
        if (size > MAX_BODY) {
          aborted = true
          res.writeHead(413, { 'content-type': 'application/json' })
          res.end('{"ok":false,"error":"payload too large"}')
          req.destroy()
          return
        }
        chunks.push(chunk)
      })

      req.on('end', () => {
        if (aborted) return
        let payload = null
        try {
          payload = JSON.parse(Buffer.concat(chunks).toString('utf8'))
        } catch {
          payload = null
        }
        res.writeHead(202, { 'content-type': 'application/json' })
        res.end('{"ok":true}')
        if (payload) {
          try {
            onHook(payload)
          } catch (error) {
            logger.error('hook handler failed', { message: error.message })
          }
        }
      })
      return
    }

    res.writeHead(404, { 'content-type': 'application/json' })
    res.end('{"ok":false,"error":"not found"}')
  })

  return new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(port, host, () => {
      logger.info(`hook server listening on http://${host}:${port}`)
      resolve(server)
    })
  })
}
