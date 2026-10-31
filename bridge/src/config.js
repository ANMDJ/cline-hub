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
  batchSize: 20,
  workspaceWhitelist: [],
  commandTools: ['run_commands', 'execute_command'],
  maxResultChars: 4000,
  maxCommands: 300,
  maxCommandChars: 2000,
  dataDir: '',
  stateFile: '',
  outboxFile: '',
  logFile: '',
  commands: {
    enabled: false,
    template: '{prompt}',
    shell: 'powershell',
    allowModes: ['plan', 'act'],
    defaultWorkspace: '',
    timeoutMs: 600000,
    batchSize: 3
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
  cfg.dataDir = cfg.dataDir ? path.resolve(cfg.dataDir) : path.join(os.homedir(), '.cline', 'data')
  cfg.stateFile = cfg.stateFile ? path.resolve(cfg.stateFile) : path.join(bridgeRoot, 'state.json')
  cfg.outboxFile = cfg.outboxFile ? path.resolve(cfg.outboxFile) : path.join(bridgeRoot, 'outbox.json')
  cfg.logFile = cfg.logFile ? path.resolve(cfg.logFile) : path.join(bridgeRoot, 'logs', 'bridge.log')

  const port = Number(cfg.hookPort)
  cfg.hookPort = Number.isInteger(port) && port > 0 && port < 65536 ? port : DEFAULTS.hookPort

  const interval = Number(cfg.pollIntervalMs)
  cfg.pollIntervalMs = Number.isFinite(interval) && interval >= 1000 ? interval : DEFAULTS.pollIntervalMs

  cfg.deviceId = String(cfg.deviceId || '').trim() || os.hostname()
  cfg.hubUrl = String(cfg.hubUrl || '').trim().replace(/\/+$/, '')
  cfg.configPath = file
  return cfg
}
