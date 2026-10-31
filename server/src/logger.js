import fs from 'node:fs'
import path from 'node:path'

const LEVELS = { debug: 10, info: 20, warn: 30, error: 40 }

/** Same shape as the bridge logger so both logs read the same. */
export function createLogger({ file, level = 'info' } = {}) {
  const threshold = LEVELS[level] ?? LEVELS.info
  let stream = null

  if (file) {
    try {
      fs.mkdirSync(path.dirname(file), { recursive: true })
      stream = fs.createWriteStream(file, { flags: 'a' })
  } catch {
      stream = null
    }
  }

  function write(levelName, message, context) {
    if ((LEVELS[levelName] ?? 0) < threshold) return
    const at = new Date().toISOString()
    const tail = context && Object.keys(context).length > 0 ? ' ' + JSON.stringify(context) : ''
    const line = `${at} ${levelName.toUpperCase().padEnd(5)} ${message}${tail}`
    const toConsole = levelName === 'error' ? console.error : console.log
    toConsole(line)
    if (stream) stream.write(line + '\n')
  }

  return {
    debug: (message, context) => write('debug', message, context),
    info: (message, context) => write('info', message, context),
    warn: (message, context) => write('warn', message, context),
    error: (message, context) => write('error', message, context),
    close: () =>
      new Promise((resolve) => {
        if (!stream) return resolve()
        stream.end(resolve)
      })
  }
}
