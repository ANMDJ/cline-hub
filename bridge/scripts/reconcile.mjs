#!/usr/bin/env node
/**
 * 命令状态对账：把 Hub 上「还是 running、但本机已经没有对应进程」的命令回写成 failed。
 *
 * bridge 常驻时每 60 秒会自动跑一遍；这个脚本用于两种场景：
 *   1. 想先看看会改什么：`npm run reconcile -- --dry-run`
 *   2. bridge 暂时没起来 / 想立刻收尾：`npm run reconcile`
 *
 * 只改状态，**不杀进程**。进程是否还在用「pid + 启动时间」双校验判断，
 * 对不上就当作 pid 已被复用（Windows 会复用 PID）。
 */
import { loadConfig } from '../src/config.js'
import { createLogger } from '../src/logger.js'
import { createCommandWorker } from '../src/command-worker.js'

const dryRun = process.argv.includes('--dry-run')
const cfg = loadConfig()
const logger = createLogger(cfg.logFile)
const worker = createCommandWorker({ cfg, logger })

try {
  const result = await worker.reconcile({ dryRun })
  console.log(JSON.stringify(result, null, 2))
  if (result.skipped) console.error(`（跳过：${result.skipped}）`)
} catch (error) {
  console.error(`✗ 对账失败：${error.message}`)
  process.exitCode = 1
} finally {
  await logger.close()
}
