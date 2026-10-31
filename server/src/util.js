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

export function toJsonArray(value) {
  if (Array.isArray(value)) return value
  return []
}

export function toJsonObject(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : {}
}

export const nowIso = () => new Date().toISOString()
