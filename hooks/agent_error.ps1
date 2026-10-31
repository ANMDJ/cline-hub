#requires -version 5.1
# Cline global hook: agent_error -> ntfy notification.
# ASCII-only on purpose (see _notify.ps1 header).
$ErrorActionPreference = 'SilentlyContinue'
try {
    & (Join-Path $PSScriptRoot '_notify.ps1') -EventName 'agent_error'
} catch {
}
exit 0
