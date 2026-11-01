#!/usr/bin/env node
/**
 * 远程命令工作目录白名单自检（无依赖）：
 *   node bridge/scripts/check-workspace-whitelist.mjs
 * 退出码非 0 表示有问题，可直接放进 CI。
 *
 * 覆盖 2026-11-01 排查出的缺口：采集侧白名单管不到「在哪执行」，
 * 手机发一句 workspace=C:\Windows\System32 就能在任意目录跑脚本。
 */
import { isWorkspaceAllowed } from '../src/command-worker.js'

const CHAT = 'C:\\Users\\alice\\.cline\\data\\workspaces\\chat'
const WL = [CHAT, 'kids_points_app']

const cases = [
  // [说明, 目录, 白名单, 期望]
  ['白名单为空 → 不限制（旧行为）', 'C:\\Windows\\System32', [], true],
  ['白名单为 null → 不限制', 'C:\\Windows\\System32', null, true],
  ['白名单目录本身', CHAT, WL, true],
  ['白名单目录的子目录', `${CHAT}\\cline-hub\\bridge`, WL, true],
  ['同名前缀的兄弟目录不能混进来', 'C:\\Users\\alice\\.cline\\data\\workspaces\\chatty', WL, false],
  ['纯名字条目按目录名精确匹配', 'D:\\work\\kids_points_app', WL, true],
  ['纯名字条目也要求精确（不能是子串）', 'D:\\work\\kids_points_app_old', WL, false],
  ['大小写不敏感', `${CHAT.toUpperCase()}\\CLINE-HUB`, WL, true],
  ['越权目录一律拒绝', 'C:\\Windows\\System32', WL, false],
  ['用 .. 跳出去会被解析后拒绝', `${CHAT}\\..\\..\\..\\..\\Windows`, WL, false]
]

let bad = 0
for (const [name, dir, whitelist, expected] of cases) {
  const actual = isWorkspaceAllowed(dir, whitelist)
  const ok = actual === expected
  console.log(`${ok ? '✓' : '✗'} ${name} → ${actual}${ok ? '' : `（期望 ${expected}）`}`)
  if (!ok) bad++
}

console.log(`共 ${cases.length} 条用例`)
console.log(bad === 0 ? '✓ 全部检查通过' : `✗ ${bad} 项未通过`)
process.exit(bad === 0 ? 0 : 1)
