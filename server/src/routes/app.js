import fs from 'node:fs'
import path from 'node:path'

import { serverRoot } from '../env.js'
import { HttpError } from '../http.js'

/**
 * App 自更新：读服务器上的发布清单。
 *
 * 清单由 `scripts/release-apk.mjs` 生成（版本 / build / notes / apkUrl / sha256），
 * 默认放在 `<server>/releases/latest.json`，可用 `HUB_APP_RELEASE_FILE` 覆盖。
 * APK 本身不进 Hub 进程：它由 Caddy 的 `file_server` 直接下发静态文件。
 */
function releaseFile() {
  const custom = process.env.HUB_APP_RELEASE_FILE?.trim()
  return custom || path.join(serverRoot, 'releases', 'latest.json')
}

export function createAppRoutes({ logger }) {
  return [
    {
      method: 'GET',
      pattern: '/api/v1/app/latest',
      auth: 'any',
      async handler() {
        const file = releaseFile()
        if (!fs.existsSync(file)) {
          throw new HttpError(404, 'no app release published yet', 'not_found')
        }
        try {
          const parsed = JSON.parse(fs.readFileSync(file, 'utf8'))
          return { ok: true, ...parsed }
        } catch (error) {
          logger.error('app release file invalid', { file, message: error.message })
          throw new HttpError(500, 'app release file is not valid JSON', 'invalid_release')
        }
      }
    }
  ]
}
