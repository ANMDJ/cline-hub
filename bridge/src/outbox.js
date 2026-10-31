import fs from 'node:fs'

const MAX_ITEMS = 2000
const REQUEST_TIMEOUT_MS = 10000

/**
 * Durable upload queue. One JSON file, FIFO, survives restarts.
 * Permanent 4xx responses are dropped (a bad payload would block forever);
 * 5xx / network errors are retried with a growing delay.
 */
export class Outbox {
  constructor({ file, hubUrl, deviceId, deviceToken, logger }) {
    this.file = file
    this.hubUrl = hubUrl
    this.deviceId = deviceId
    this.deviceToken = deviceToken
    this.logger = logger
    this.items = []
    this.flushing = false
    this.failures = 0
    this.retryAt = 0
    this.load()
  }

  load() {
    try {
      if (!fs.existsSync(this.file)) return
      const parsed = JSON.parse(fs.readFileSync(this.file, 'utf8'))
      if (Array.isArray(parsed)) this.items = parsed
    } catch (error) {
      this.logger.warn('outbox load failed, starting empty', { message: error.message })
      this.items = []
    }
  }

  save() {
    try {
      fs.writeFileSync(this.file, JSON.stringify(this.items), 'utf8')
    } catch (error) {
      this.logger.error('outbox save failed', { message: error.message })
    }
  }

  add(item) {
    this.items.push(item)
    if (this.items.length > MAX_ITEMS) {
      const dropped = this.items.splice(0, this.items.length - MAX_ITEMS)
      this.logger.warn('outbox overflow, dropped oldest', { dropped: dropped.length })
    }
    this.save()
  }

  get pending() {
    return this.items.length
  }

  endpointFor(item) {
    return item.kind === 'hook'
      ? `${this.hubUrl}/api/v1/hooks`
      : `${this.hubUrl}/api/v1/sessions`
  }

  async flush() {
    if (!this.hubUrl || this.items.length === 0) return
    if (this.flushing || Date.now() < this.retryAt) return

    this.flushing = true
    try {
      while (this.items.length > 0) {
        const outcome = await this.send(this.items[0])
        if (outcome === 'retry') {
          this.failures += 1
          this.retryAt = Date.now() + Math.min(60000, 2000 * this.failures)
          return
        }
        this.items.shift()
        this.save()
        this.failures = 0
        this.retryAt = 0
      }
    } finally {
      this.flushing = false
    }
  }

  async send(item) {
    const headers = { 'content-type': 'application/json; charset=utf-8' }
    if (this.deviceToken) headers.authorization = `Bearer ${this.deviceToken}`

    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS)
    try {
      const response = await fetch(this.endpointFor(item), {
        method: 'POST',
        headers,
        body: JSON.stringify({ deviceId: this.deviceId, ...item.body }),
        signal: controller.signal
      })
      if (response.ok) return 'ok'
      if (response.status === 408 || response.status === 429 || response.status >= 500) return 'retry'
      this.logger.warn('outbox dropped item (client error)', { status: response.status, kind: item.kind })
      return 'drop'
    } catch {
      return 'retry'
    } finally {
      clearTimeout(timer)
    }
  }
}
