import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

/** 无 .git 时也认这些，作为二级信号。 */
const MARKER_FILES = ['pubspec.yaml', 'package.json', 'go.mod', 'Cargo.toml', 'pyproject.toml', 'gradlew', 'pom.xml']
const MAX_DEPTH = 8

const cache = new Map()

function hasGit(dir) {
  try {
    fs.statSync(path.join(dir, '.git'))
    return true
  } catch {
    return false
  }
}

function hasMarker(dir) {
  for (const name of MARKER_FILES) {
    if (fs.existsSync(path.join(dir, name))) return true
  }
  try {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (entry.isFile() && /\.(sln|csproj)$/i.test(entry.name)) return true
    }
  } catch {}
  return false
}

function ancestors(start) {
  const chain = []
  let dir = start
  for (let i = 0; i < MAX_DEPTH; i += 1) {
    chain.push(dir)
    const parent = path.dirname(dir)
    if (parent === dir) break
    dir = parent
  }
  return chain
}

function detect(start, home) {
  const chain = ancestors(start)
  // 第一轮只看 .git：否则 .../cline-hub/bridge 会被自己的 package.json 抢走。
  for (const dir of chain) {
    if (hasGit(dir)) return { project: path.basename(dir), projectRoot: dir, projectKind: 'project', via: 'git' }
  }
  for (const dir of chain) {
    if (hasMarker(dir)) return { project: path.basename(dir), projectRoot: dir, projectKind: 'project', via: 'marker' }
  }
  const lower = start.toLowerCase()
  const underHome = lower === home || lower.startsWith(home + path.sep)
  return {
    project: underHome ? '' : path.basename(start),
    projectRoot: start,
    projectKind: underHome ? 'loose' : 'project',
    via: 'fallback'
  }
}

/**
 * 从会话的工作目录向上找「项目根」。
 *
 * - 有 .git 的最近目录       → 项目根（via=git）
 * - 有构建/包标记的最近目录   → 项目根（via=marker）
 * - 都没有但在家目录之下      → 散会话（projectKind=loose，不参与项目分组）
 * - 其余                     → 用目录名当项目名
 */
export function projectInfo(root) {
  const raw = String(root ?? '').trim()
  if (!raw) return { project: '', projectRoot: '', projectKind: 'loose', via: 'empty' }
  const start = path.resolve(raw)
  const key = start.toLowerCase()
  const cached = cache.get(key)
  if (cached) return cached
  const info = detect(start, path.resolve(os.homedir()).toLowerCase())
  cache.set(key, info)
  return info
}