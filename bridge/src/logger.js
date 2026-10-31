import fs from 'node:fs'
import path from 'node:path'

const LEVELS = { info: 'INFO ', warn: 'WARN ', error: 'ERROR' }

/** File + console logger. Log file is UTF-8 so Chinese stays readable. */
export function createLogger(file) {
  fs.mkdirSync(path.dirname(file), { recursive: true })
  const stream = fs.createWriteStream(file, { flags: 'a', encoding: 'utf8' })

  const write = (level, message, extra) => {
    let suffix = ''
    if (extra !== undefined) {
      try {
        suffix = ' ' + JSON.stringify(extra)
      } catch {
        suffix = ' ' + String(extra)
      }
    }
    const line = `${new Date().toISOString()} ${LEVELS[level] ?? level} ${message}${suffix}`
    console.log(line)
    stream.write(line + '\n')
  }

  return {
    info: (m, e) => write('info', m, e),
    warn: (m, e) => write('warn', m, e),
    error: (m, e) => write('error', m, e),
    close: () => new Promise((resolve) => stream.end(resolve))
  }
}
