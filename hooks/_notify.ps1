#requires -version 5.1
# Cline global hook core.
# IMPORTANT: keep this file ASCII-only. Windows PowerShell 5.1 decodes
# BOM-less files as the ANSI code page, so non-ASCII literals would be garbled.
# All dynamic Chinese text arrives via stdin (read explicitly as UTF-8).
param([string]$EventName = 'agent_end')

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$script:ClineDir = Join-Path $env:USERPROFILE '.cline'
$script:LogPath = Join-Path $script:ClineDir 'notify.log'
$script:ConfigPath = Join-Path $script:ClineDir 'notify.config.json'

function Write-HookLog {
    param([string]$Message)
    try {
        if (-not (Test-Path -LiteralPath $script:ClineDir)) {
            New-Item -ItemType Directory -Path $script:ClineDir -Force | Out-Null
        }
        $enc = New-Object System.Text.UTF8Encoding($false)
        $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' [' + $EventName + '] ' + $Message + "`r`n"
        [System.IO.File]::AppendAllText($script:LogPath, $line, $enc)
    } catch { }
}

function Get-HookConfig {
    $cfg = [ordered]@{
        enabled     = $true
        ntfyBase    = 'https://ntfy.sh'
        topic       = 'cline-lw-7f3a9c2e5b1d4a86'
        token       = ''
        bridgeUrl   = 'http://127.0.0.1:3210/hook'
        titlePrefix = 'Cline'
        maxChars    = 500
    }
    try {
        if (Test-Path -LiteralPath $script:ConfigPath) {
            $raw = [System.IO.File]::ReadAllText($script:ConfigPath, [System.Text.Encoding]::UTF8)
            $obj = $raw | ConvertFrom-Json
            foreach ($key in @($cfg.Keys)) {
                $prop = $obj.PSObject.Properties[$key]
                if ($null -ne $prop -and $null -ne $prop.Value -and "$($prop.Value)" -ne '') {
                    $cfg[$key] = $prop.Value
                }
            }
        }
    } catch {
        Write-HookLog ('config read failed: ' + $_.Exception.Message)
    }
    return $cfg
}

function Read-HookInput {
    try {
        $stdin = [Console]::OpenStandardInput()
        $reader = New-Object System.IO.StreamReader($stdin, [System.Text.Encoding]::UTF8, $true)
        $text = $reader.ReadToEnd()
        $reader.Dispose()
        return $text
    } catch {
        return ''
    }
}

function Get-WorkspaceName {
    param($Payload)
    $candidates = @()
    try { if ($Payload.workspaceRoots) { foreach ($r in $Payload.workspaceRoots) { $candidates += [string]$r } } } catch { }
    try { if ($Payload.workspace -and $Payload.workspace.rootPath) { $candidates += [string]$Payload.workspace.rootPath } } catch { }
    try { if ($Payload.cwd) { $candidates += [string]$Payload.cwd } } catch { }
    foreach ($c in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($c)) {
            $leaf = Split-Path -Leaf $c.TrimEnd([char[]]@('\', '/'))
            if ($leaf) { return $leaf }
        }
    }
    return 'workspace'
}

function Get-HookText {
    param($Payload)
    $found = @()
    try { if ($Payload.turn -and $Payload.turn.outputText) { $found += [string]$Payload.turn.outputText } } catch { }
    foreach ($name in @('outputText', 'message', 'error', 'reason', 'status', 'text')) {
        try {
            $prop = $Payload.PSObject.Properties[$name]
            if ($null -ne $prop -and $null -ne $prop.Value -and "$($prop.Value)" -ne '') { $found += [string]$prop.Value }
        } catch { }
    }
    foreach ($f in $found) {
        if (-not [string]::IsNullOrWhiteSpace($f)) { return $f.Trim() }
    }
    return ''
}

function Send-Ntfy {
    param($Config, [string]$Title, [string]$Message, [int]$Priority, [string]$Tag)
    $body = [ordered]@{
        topic    = [string]$Config.topic
        title    = $Title
        message  = $Message
        priority = $Priority
        tags     = @($Tag)
    }
    $json = ConvertTo-Json -InputObject $body -Compress -Depth 5
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $headers = @{}
    if ($Config.token) { $headers['Authorization'] = 'Bearer ' + [string]$Config.token }
    $uri = ([string]$Config.ntfyBase).TrimEnd('/')
    Invoke-RestMethod -Method Post -Uri $uri -Body $bytes -ContentType 'application/json; charset=utf-8' -Headers $headers -TimeoutSec 8 | Out-Null
}

function Send-Bridge {
    param($Config, [string]$RawJson)
    if (-not $Config.bridgeUrl) { return }
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($RawJson)
        Invoke-RestMethod -Method Post -Uri ([string]$Config.bridgeUrl) -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 2 | Out-Null
        Write-HookLog 'bridge ok'
    } catch {
        Write-HookLog 'bridge down'
    }
}

try {
    $cfg = Get-HookConfig
    if (-not $cfg.enabled) { Write-HookLog 'disabled'; exit 0 }

    $raw = Read-HookInput
    if ([string]::IsNullOrWhiteSpace($raw)) { Write-HookLog 'empty stdin, skipped'; exit 0 }

    $payload = $null
    try { $payload = $raw | ConvertFrom-Json } catch { $payload = $null }
    if ($null -eq $payload) { Write-HookLog 'stdin is not valid json, skipped'; exit 0 }

    $ws = Get-WorkspaceName -Payload $payload
    $text = Get-HookText -Payload $payload

    $label = 'DONE'
    $priority = 3
    $tag = 'white_check_mark'
    if ($EventName -eq 'agent_error') { $label = 'ERROR'; $priority = 4; $tag = 'warning' }
    elseif ($EventName -eq 'agent_abort') { $label = 'ABORT'; $priority = 3; $tag = 'octagonal_sign' }
    elseif ($EventName -ne 'agent_end') { $label = $EventName.ToUpperInvariant(); $tag = 'robot' }

    $max = [int]$cfg.maxChars
    if ($max -lt 80) { $max = 80 }
    if ($text.Length -gt $max) { $text = $text.Substring(0, $max) + ' ...' }
    if ([string]::IsNullOrWhiteSpace($text)) { $text = '(no text in payload)' }

    $sessionId = ''
    try { if ($payload.taskId) { $sessionId = [string]$payload.taskId } } catch { }
    if (-not $sessionId) { try { if ($payload.sessionId) { $sessionId = [string]$payload.sessionId } } catch { } }

    $title = '{0} {1} - {2}' -f $cfg.titlePrefix, $label, $ws
    if ($sessionId) { $message = $text + "`n`n" + $ws + ' / ' + $sessionId }
    else { $message = $text + "`n`n" + $ws }

    try {
        Send-Ntfy -Config $cfg -Title $title -Message $message -Priority $priority -Tag $tag
        Write-HookLog ('ntfy ok -> ' + $cfg.ntfyBase + ' / ' + $cfg.topic)
    } catch {
        Write-HookLog ('ntfy failed: ' + $_.Exception.Message)
    }

    Send-Bridge -Config $cfg -RawJson $raw
} catch {
    Write-HookLog ('fatal: ' + $_.Exception.Message)
}
exit 0
