#!/usr/bin/env node
/**
 * 打包 APK 并生成发布清单。
 *
 * 前提：Android SDK + JDK 17（`flutter doctor --android-licenses` 过）。
 * 本机 2026-11-02 缺 SDK，所以脚本存在但跑不出包 —— 补齐工具链后直接：
 *
 *   node app/scripts/release-apk.mjs --notes "修复 ACT 模式;长文本折叠" \
 *     --base-url https://hub.littlewish.top:8443/app
 *
 * 产物：
 *   app/dist/cline-console-<version>.apk
 *   app/dist/latest.json          ← 上传到服务器的 releases/latest.json
 */
import { execSync } from 'node:child_process'
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const appRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const distDir = path.join(appRoot, 'dist')

function arg(name, fallback = '') {
  const index = process.argv.indexOf(`--${name}`)
  return index > 0 && process.argv[index + 1] ? process.argv[index + 1] : fallback
}

function readPubspecVersion() {
  const text = fs.readFileSync(path.join(appRoot, 'pubspec.yaml'), 'utf8')
  const hit = /^version:\s*([0-9A-Za-z.+-]+)\+(\d+)\s*$/m.exec(text)
  if (!hit) throw new Error('pubspec.yaml 里找不到 version: x.y.z+n')
  return { version: hit[1], build: Number(hit[2]) }
}

function assertVersionDartMatches(version, build) {
  const file = path.join(appRoot, 'lib', 'src', 'data', 'app_version.dart')
  const text = fs.readFileSync(file, 'utf8')
  const v = /kAppVersion\s*=\s*'([^']+)'/.exec(text)?.[1]
  const b = Number(/kAppBuild\s*=\s*(\d+)/.exec(text)?.[1])
  if (v !== version || b !== build) {
    throw new Error(
      `版本不一致：pubspec=${version}+${build}，app_version.dart=${v}+${b}。` +
      '先把两处改成同一个版本再打包。'
    )
  }
}

const { version, build } = readPubspecVersion()
assertVersionDartMatches(version, build)

console.log(`→ 打包 ${version}+${build}`)
// Windows 上 flutter 是 .bat，execFileSync 直接调不到；构建命令的参数全部来自
// 上面校验过的 pubspec，没有外部输入，这里用 execSync 是安全的。
const javaHome = process.env.JAVA_HOME ?? ''
if (!/\b(17|21|22|23)\b/.test(javaHome)) {
  console.warn(
    `! JAVA_HOME=${javaHome || '(empty)'}：AGP 9 / Gradle 9 需要 JDK 17+，` +
    '否则会在 Gradle 启动阶段失败。'
  )
}
execSync(
  `flutter build apk --release --build-name=${version} --build-number=${build}`,
  { cwd: appRoot, stdio: 'inherit', shell: true }
)

const apk = path.join(appRoot, 'build', 'app', 'outputs', 'flutter-apk', 'app-release.apk')
if (!fs.existsSync(apk)) throw new Error(`没有找到产物：${apk}`)

fs.mkdirSync(distDir, { recursive: true })
const target = path.join(distDir, `cline-console-${version}.apk`)
fs.copyFileSync(apk, target)

const sha256 = crypto.createHash('sha256').update(fs.readFileSync(target)).digest('hex')
const baseUrl = arg('base-url', 'https://hub.littlewish.top:8443/app').replace(/\/+$/, '')
const notes = arg('notes', '')
  .split(';')
  .map((item) => item.trim())
  .filter(Boolean)

const manifest = {
  version,
  build,
  notes,
  apkUrl: `${baseUrl}/cline-console-${version}.apk`,
  sha256,
  publishedAt: new Date().toISOString()
}
fs.writeFileSync(path.join(distDir, 'latest.json'), `${JSON.stringify(manifest, null, 2)}\n`, 'utf8')

console.log('\n产物：')
console.log(`  ${target}`)
console.log(`  ${path.join(distDir, 'latest.json')}`)
console.log(`  sha256 ${sha256}`)
console.log('\n上传（服务器）：')
console.log('  scp app/dist/*.apk app/dist/latest.json ubuntu@82.157.153.22:/tmp/')
console.log('  ssh ubuntu@82.157.153.22 \\')
console.log('    "sudo mkdir -p /var/www/cline-hub/app /opt/cline-hub/releases && \\')
console.log('     sudo cp /tmp/cline-console-*.apk /var/www/cline-hub/app/ && \\')
console.log('     sudo cp /tmp/latest.json /opt/cline-hub/releases/latest.json && \\')
console.log('     sudo chown -R caddy:caddy /var/www/cline-hub && sudo systemctl restart cline-hub"')
