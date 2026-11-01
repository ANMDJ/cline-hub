import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

export const bridgeRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')

const DEFAULTS = {
  hubUrl: '',
  deviceId: '',
  deviceToken: '',
  hookHost: '127.0.0.1',
  hookPort: 3210,
  pollIntervalMs: 5000,
  /**
   * 进行中会话的重扫间隔：3s 让「执行中」和逐条回复在手机上跟得上，
   * 同时靠 transcript 水位线把没变化的会话直接跳过，不会每 3 秒打一次 Hub。
   */
  runningPollIntervalMs: 3000,
  batchSize: 20,
  workspaceWhitelist: [],
  commandTools: ['run_commands', 'execute_command'],
  maxResultChars: 4000,
  maxCommands: 300,
  maxCommandChars: 2000,
  /** 单条消息在 Hub 里的长度上限（超出截断，手机不渲染超长 blob）。 */
  maxTextChars: 2000,
  /** 一次 outbox 最多带多少条消息，避免单个请求过大。 */
  messageBatch: 40,
  dataDir: '',
  stateFile: '',
  outboxFile: '',
  logFile: '',
  commands: {
    enabled: false,
    /** 'shell' = 把 prompt 当脚本跑；'cline' = 交给 Cline CLI 开/续会话。 */
    runner: 'shell',
    template: '{prompt}',
    shell: 'powershell',
    allowModes: ['plan', 'act'],
    defaultWorkspace: '',
    timeoutMs: 600000,
    batchSize: 3,
    cline: {
      /** 留空则用 PATH 上的 cline；Windows 上通常是绝对路径的 cline.cmd。 */
      bin: '',
      /** 两种模式各自的固定参数。 */
      planArgs: ['-p'],
      actArgs: ['--auto-approve', 'true'],
      /** 额外参数（模型、thinking 等）。 */
      extraArgs: [],
      /** 带 sessionId 时是否用 --id 续会话。 */
      resume: true,
      /** CLI 跑一整轮通常比 shell 命令久。 */
      timeoutMs: 1800000
    }
  }
}

/** Load bridge/config.json (created from config.example.json on first run). */
export function loadConfig() {
  const file = path.join(bridgeRoot, 'config.json')
  const example = path.join(bridgeRoot, 'config.example.json')

  if (!fs.existsSync(file) && fs.existsSync(example)) {
    fs.copyFileSync(example, file)
  }

  let user = {}
  if (fs.existsSync(file)) {
    user = JSON.parse(fs.readFileSync(file, 'utf8'))
  }

  const cfg = { ...DEFAULTS, ...user }
  cfg.commands = { ...DEFAULTS.commands, ...(user.commands ?? {}) }
  cfg.commands.cline = { ...DEFAULTS.commands.cline, ...(user.commands?.cline ?? {}) }
  cfg.dataDir = cfg.dataDir ? path.resolve(cfg.dataDir) : path.join(os.homedir(), '.cline', 'data')
  cfg.stateFile = cfg.stateFile ? path.resolve(cfg.stateFile) : path.join(bridgeRoot, 'state.json')
  cfg.outboxFile = cfg.outboxFile ? path.resolve(cfg.outboxFile) : path.join(bridgeRoot, 'outbox.json')
  cfg.logFile = cfg.logFile ? path.resolve(cfg.logFile) : path.join(bridgeRoot, 'logs', 'bridge.log')

  const port = Number(cfg.hookPort)
  cfg.hookPort = Number.isInteger(port) && port > 0 && port < 65536 ? port : DEFAULTS.hookPort

  const interval = Number(cfg.pollIntervalMs)
  cfg.pollIntervalMs = Number.isFinite(interval) && interval >= 1000 ? interval : DEFAULTS.pollIntervalMs

  const liveInterval = Number(cfg.runningPollIntervalMs)
  cfg.runningPollIntervalMs = Number.isFinite(liveInterval) && liveInterval >= 1000
    ? liveInterval
    : DEFAULTS.runningPollIntervalMs

  cfg.deviceId = String(cfg.deviceId || '').trim() || os.hostname()
  cfg.hubUrl = String(cfg.hubUrl || '').trim().replace(/\/+$/, '')
  cfg.configPath = file
  return cfg
}
