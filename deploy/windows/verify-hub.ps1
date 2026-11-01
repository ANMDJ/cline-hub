#requires -Version 5.1
<#
.SYNOPSIS
  One-shot end-to-end check for the Cline Hub bridge on this machine.

.DESCRIPTION
  Checks, in order:
    1. bridge process is listening on hookPort (default 3210) and its log tail
    2. Hub health endpoint
    3. (optional) creates a real command, polls it until a terminal status,
       and prints resultText / errorText  -> proves "phone -> cline session" works
    4. (optional) reads the newest messages of -SessionId and looks for -Prompt,
       -> proves the bridge picked the new message up and pushed it to the Hub
    5. prints the newest hook events -> proves completion notifications land

  The script is ASCII-only on purpose: Windows PowerShell 5.1 decodes scripts
  without a BOM as ANSI, so any non-ASCII literal would be garbled.

  Requires nothing but PowerShell 5.1 (no modules, no node).

.PARAMETER AppToken
  Token with the `app` role (the one shown on the App settings page).
  Required to create a command.
  Without it the script only performs read-only checks.

.PARAMETER SessionId
  Existing Cline session to resume (bridge runs `cline --id <id>`).
  Omit to create a brand new session (`cline -c <workspace>`).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File deploy\windows\verify-hub.ps1

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File deploy\windows\verify-hub.ps1 `
    -AppToken clh_xxxxxxxx -SessionId 1791688899478_78ppl

.NOTES
  Exit code 0 = every executed check passed, 1 = at least one failed.
#>
[CmdletBinding()]
param(
  [string]$BaseUrl,
  [string]$DeviceId,
  [string]$AppToken,
  [string]$SessionId,
  [string]$Prompt = 'reply with exactly: OK',
  [ValidateSet('plan', 'act')][string]$Mode = 'plan',
  [int]$TimeoutSec = 300,
  [string]$Workspace,
  [string]$BridgeLog
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:Failed = 0
$script:Warned = 0

function Write-Pass([string]$Text) { Write-Host ("  [PASS] " + $Text) -ForegroundColor Green }
function Write-Fail([string]$Text) { Write-Host ("  [FAIL] " + $Text) -ForegroundColor Red; $script:Failed++ }
function Write-Warn([string]$Text) { Write-Host ("  [WARN] " + $Text) -ForegroundColor Yellow; $script:Warned++ }
function Write-Info([string]$Text) { Write-Host ("  " + $Text) -ForegroundColor DarkGray }
function Write-Step([string]$Text) { Write-Host ""; Write-Host $Text -ForegroundColor Cyan }

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$bridgeRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $scriptDir)) 'bridge'
$configPath = Join-Path $bridgeRoot 'config.json'

Write-Host "Cline Hub - end-to-end self check" -ForegroundColor White
Write-Info ("bridge root : " + $bridgeRoot)

if (-not (Test-Path -LiteralPath $configPath)) {
  Write-Fail ("config not found: " + $configPath)
  exit 1
}

$cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $BaseUrl) { $BaseUrl = [string]$cfg.hubUrl }
if (-not $DeviceId) { $DeviceId = [string]$cfg.deviceId }
if (-not $BridgeLog) { $BridgeLog = Join-Path $bridgeRoot 'logs\bridge.log' }
if (-not $BaseUrl) { Write-Fail 'hubUrl is empty in bridge/config.json'; exit 1 }
$BaseUrl = $BaseUrl.TrimEnd('/')

$deviceToken = [string]$cfg.deviceToken
$hookPort = 3210
if ($cfg.hookPort) { $hookPort = [int]$cfg.hookPort }

Write-Info ("hub url     : " + $BaseUrl)
Write-Info ("device id   : " + $DeviceId)
Write-Info ("hook port   : " + $hookPort)
if (-not $AppToken) { Write-Info "app token   : (not given -> read-only mode)" }

if (-not $BaseUrl) { Write-Fail 'hubUrl is empty in config.json'; exit 1 }
if (-not $DeviceId) { Write-Fail 'deviceId is empty in config.json'; exit 1 }
if (-not $deviceToken) { Write-Fail 'deviceToken is empty in config.json'; exit 1 }

function Invoke-Hub {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Path,
    $Body,
    [string]$Token
  )
  $uri = $BaseUrl + $Path
  $headers = @{ accept = 'application/json' }
  if ($Token) { $headers['authorization'] = 'Bearer ' + $Token }
  $ps = @{
    Method     = $Method
    Uri        = $uri
    Headers    = $headers
    TimeoutSec = 30
    UseBasicParsing = $true
  }
  if ($null -ne $Body) {
    $json = $Body | ConvertTo-Json -Depth 8 -Compress
    $ps['Body'] = [System.Text.Encoding]::UTF8.GetBytes($json)
    $ps['ContentType'] = 'application/json; charset=utf-8'
  }
  return Invoke-RestMethod @ps
}

function Format-Block {
  param([string]$Text, [int]$Max = 700)
  if (-not $Text) { return '    (empty)' }
  $t = ($Text -replace "`r`n", "`n").Trim()
  if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) + ' ...[truncated]' }
  return (($t -split "`n" | ForEach-Object { '    ' + $_ }) -join "`n")
}

# ------------------------------------------------------------- 1. bridge alive
Write-Step '1) bridge process / log tail'
$listening = $false
try {
  $probe = Invoke-WebRequest -Uri ('http://127.0.0.1:' + $hookPort + '/health') -UseBasicParsing -TimeoutSec 3
  if ($probe.StatusCode -eq 200) { $listening = $true }
} catch {}
try {
  $conn = Get-NetTCPConnection -LocalPort $hookPort -State Listen -ErrorAction Stop
  if ($conn) { $listening = $true }
} catch {
  $hit = netstat -ano | Select-String (':' + $hookPort + '\s+\S+\s+LISTENING')
  if ($hit) { $listening = $true }
}
if ($listening) {
  Write-Pass ('something is listening on port ' + $hookPort)
} else {
  Write-Fail ('nothing listening on port ' + $hookPort + ' - start the bridge first (deploy/windows/ClineBridge.vbs)')
}

if (Test-Path -LiteralPath $BridgeLog) {
  Write-Info ('log tail: ' + $BridgeLog)
  Get-Content -LiteralPath $BridgeLog -Tail 10 -Encoding UTF8 | ForEach-Object {
    Write-Host ('    ' + $_) -ForegroundColor DarkGray
  }
} else {
  Write-Warn ('bridge log not found: ' + $BridgeLog)
}

# --------------------------------------------------------------- 2. hub health
Write-Step '2) hub health'
$health = $null
try {
  $health = Invoke-Hub -Method 'GET' -Path '/api/v1/health'
  if ($health.ok -eq $true) {
    Write-Pass ('hub ok - db ' + $health.db.latencyMs + 'ms, uptime ' + $health.uptimeSec + 's, version ' + $health.version)
  } else {
    Write-Fail 'hub replied but ok != true'
  }
} catch {
  Write-Fail ('hub unreachable: ' + $_.Exception.Message)
}

# --------------------------------------------------------- 3. command round-trip
$commandId = $null
$lastStatus = ''
$finalCommand = $null
if (-not $AppToken) {
  Write-Step '3) command round-trip - SKIPPED'
  Write-Info 'pass -AppToken <app token from the App settings page> to run it'
} elseif ($null -eq $health) {
  Write-Step '3) command round-trip - SKIPPED'
  Write-Info 'hub is unreachable, nothing to do'
} else {
  Write-Step '3) command round-trip (App -> hub -> bridge -> cline)'
  $payload = @{ deviceId = $DeviceId; prompt = $Prompt; mode = $Mode }
  if ($SessionId) { $payload['sessionId'] = $SessionId }
  if ($Workspace) { $payload['workspace'] = $Workspace }
  if ($SessionId) {
    Write-Info ('resume session : ' + $SessionId)
  } else {
    Write-Info 'resume session : (none - bridge will start a new cline session)'
  }
  try {
    $created = Invoke-Hub -Method 'POST' -Path '/api/v1/commands' -Body $payload -Token $AppToken
    $commandId = [string]$created.command.id
    Write-Pass ('command created: ' + $commandId + ' (status ' + $created.command.status + ')')
  } catch {
    Write-Fail ('command create rejected: ' + $_.Exception.Message)
  }

  if ($commandId) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Seconds 3
      try {
        $cur = Invoke-Hub -Method 'GET' -Path ('/api/v1/commands/' + $commandId) -Token $deviceToken
      } catch {
        Write-Info ('poll error: ' + $_.Exception.Message)
        continue
      }
      $finalCommand = $cur.command
      $st = [string]$cur.command.status
      if ($st -ne $lastStatus) {
        Write-Info ('status -> ' + $st + ' (delivered=' + $cur.command.deliveredAt + ', started=' + $cur.command.startedAt + ')')
        $lastStatus = $st
      }
      if ($st -eq 'done' -or $st -eq 'failed' -or $st -eq 'cancelled') { break }
    }
    $seconds = [int]$sw.Elapsed.TotalSeconds

    if ($lastStatus -eq '') {
      Write-Fail ('no status update within ' + $TimeoutSec + 's - is the bridge really polling?')
    } elseif ($lastStatus -eq 'pending') {
      Write-Fail ('still pending after ' + $seconds + 's - bridge never claimed it (check bridge log)')
    } elseif ($lastStatus -eq 'delivered') {
      Write-Fail ('claimed but never started after ' + $seconds + 's - check bridge log for spawn errors')
    } elseif ($lastStatus -eq 'running') {
      Write-Warn ('still running after ' + $seconds + 's - a real cline turn can take minutes; re-run with -SessionId to check the transcript')
    } elseif ($lastStatus -eq 'done') {
      Write-Pass ('command done in ' + $seconds + 's')
    } else {
      Write-Fail ("command ended as '" + $lastStatus + "' after " + $seconds + 's')
    }

    if ($finalCommand) {
      if ($finalCommand.errorText) { Write-Host ('    errorText: ' + $finalCommand.errorText) -ForegroundColor Red }
      if ($finalCommand.resultText) {
        Write-Info 'resultText:'
        Write-Host (Format-Block ([string]$finalCommand.resultText)) -ForegroundColor DarkGray
      }
    }
  }
}

# ------------------------------------------------------- 4. transcript of session
Write-Step '4) newest messages of a cline session'
$checkId = $SessionId
if (-not $checkId) {
  try {
    $latest = Invoke-Hub -Method 'GET' -Path '/api/v1/sessions?limit=1' -Token $deviceToken
    $checkId = [string](@($latest.items)[0].sessionId)
    Write-Info ('no -SessionId; checking newest session: ' + $checkId)
  } catch {
    Write-Warn ('cannot list sessions: ' + $_.Exception.Message)
  }
}
if (-not $checkId) {
  Write-Warn 'no session id available, skipped'
} else {
  try {
    $qs = '/api/v1/sessions/' + [uri]::EscapeDataString($checkId) + '/messages?limit=800'
    $data = Invoke-Hub -Method 'GET' -Path $qs -Token $deviceToken
    $items = @($data.items)
    Write-Info ('stored messages: ' + $items.Count)
    if ($items.Count -eq 0) {
      Write-Fail 'no messages stored for this session - bridge transcript sync did not run'
    } else {
      Write-Pass ('message stream present (' + $items.Count + ' rows)')
      foreach ($m in @($items | Select-Object -Last 6)) {
        $text = [string]$m.text
        $text = ($text -replace "`r?`n", ' ')
        if ($text.Length -gt 90) { $text = $text.Substring(0, 90) + '...' }
        Write-Host ('    #' + $m.seq + ' ' + $m.role + '/' + $m.kind + ' : ' + $text) -ForegroundColor DarkGray
      }

      $hit = @($items | Where-Object {
        $_.role -eq 'user' -and $_.text -and ([string]$_.text).Contains($Prompt)
      })
      if ($hit.Count -gt 0) {
        Write-Pass 'the prompt sent from the phone is inside the cline session'
      } elseif ($lastStatus -eq 'running' -or $lastStatus -eq 'pending') {
        Write-Warn 'prompt not in transcript yet - bridge scans every ~3s, re-run in a moment'
      } elseif ($lastStatus -eq 'done') {
        Write-Warn 'prompt not found in transcript - cline may have answered without echoing it'
      }
    }
  } catch {
    Write-Fail ('messages fetch failed: ' + $_.Exception.Message)
  }
}

# -------------------------------------------------------------- 5. hook events
Write-Step '5) newest hook events (completion notifications)'
try {
  $hooks = Invoke-Hub -Method 'GET' -Path '/api/v1/hooks?limit=8' -Token $deviceToken
  $list = @($hooks.items)
  if ($list.Count -eq 0) {
    Write-Warn 'no hook events at all'
  } else {
    foreach ($h in $list) {
      $sid = [string]$h.sessionId
      if (-not $sid) { $sid = '-' }
      $title = [string]$h.title
      if (-not $title) { $title = [string]$h.message }
      if ($title.Length -gt 60) { $title = $title.Substring(0, 60) + '...' }
      Write-Host ('    #' + $h.id + ' ' + $h.event + ' session=' + $sid + ' ' + $h.createdAt + ' | ' + $title) -ForegroundColor DarkGray
    }
    $done = @($list | Where-Object { ([string]$_.event).StartsWith('session_') })
    if ($done.Count -gt 0) {
      Write-Pass 'bridge completion notification found (' + $done[0].event + ')'
    } else {
      Write-Warn 'no session_* event yet - it is emitted only when a session goes running -> finished'
    }
  }
} catch {
  Write-Fail ('hooks fetch failed: ' + $_.Exception.Message)
}

# -------------------------------------------------------------------- summary
Write-Step 'summary'
Write-Host ('  failed=' + $script:Failed + '  warnings=' + $script:Warned)
if ($script:Failed -gt 0) {
  Write-Host '  RESULT: FAIL' -ForegroundColor Red
  exit 1
}
Write-Host '  RESULT: OK' -ForegroundColor Green
exit 0

