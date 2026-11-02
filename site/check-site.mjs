#!/usr/bin/env node
/**
 * 静态站自检（无依赖）：标签配对 / CSS 括号 / 引用文件 / 锚点 id / 禁用外链资源
 *   node site/check-site.mjs
 * 退出码非 0 表示有问题，可直接放进 CI。
 */
import { readFileSync, existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const read = (f) => readFileSync(join(here, f), 'utf8')

const html = read('index.html')
const css = read('styles.css')
let bad = 0

const tags = ['div', 'section', 'article', 'nav', 'header', 'footer', 'main',
              'table', 'thead', 'tbody', 'tr', 'details', 'pre', 'button']
for (const tag of tags) {
  const open = (html.match(new RegExp('<' + tag + '[ >]', 'g')) || []).length
  const close = (html.match(new RegExp('</' + tag + '>', 'g')) || []).length
  if (open !== close) { console.log(`✗ 标签不配对: <${tag}> ${open} 开 / ${close} 闭`); bad++ }
}

const ob = (css.match(/{/g) || []).length
const cb = (css.match(/}/g) || []).length
if (ob !== cb) { console.log(`✗ CSS 括号不配对: ${ob} 开 / ${cb} 闭`); bad++ }

const refs = [...new Set([...html.matchAll(/(?:href|src)="([^"#][^"]*)"/g)].map((m) => m[1]))]
// /app/* 是 Caddy 在运行时提供的目录（APK 与更新清单不在 site/ 里），不算静态站文件
const RUNTIME_PREFIXES = ['/app/']
for (const r of refs) {
  if (/^https?:|^mailto:/.test(r)) { console.log(`! 外链资源（确认可接受）: ${r}`); continue }
  if (RUNTIME_PREFIXES.some((p) => r.startsWith(p))) { console.log(`! 运行时资源（Caddy 直出）: ${r}`); continue }
  if (!existsSync(join(here, r.replace(/^\//, '')))) { console.log(`✗ 引用了不存在的文件: ${r}`); bad++ }
}

const ids = new Set([...html.matchAll(/id="([^"]+)"/g)].map((m) => m[1]))
const anchors = [...new Set([...html.matchAll(/href="#([\w-]+)"/g)].map((m) => m[1]))]
const missing = anchors.filter((a) => !ids.has(a))
if (missing.length) { console.log(`✗ 锚点没有对应 id: ${missing.join(', ')}`); bad++ }

console.log(`html ${html.length}B / css ${css.length}B / 区块 ${ids.size} 个 / 锚点 ${anchors.length} 个`)
console.log(bad === 0 ? '✓ 全部检查通过' : `✗ ${bad} 项未通过`)
process.exit(bad === 0 ? 0 : 1)
