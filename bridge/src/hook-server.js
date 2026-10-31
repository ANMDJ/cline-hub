import http from 'node:http'

const MAX_BODY = 2 * 1024 * 1024

/**
 * Local-only HTTP endpoint the PowerShell hook posts to.
 * Responds 202 immediately so the hook exits fast; the payload is handed to
 * onHook afterwards (sync, cheap: it only appends to the outbox).
 */
export function startHookServer({ host = '127.0.0.1', port, onHook, logger }) {
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
