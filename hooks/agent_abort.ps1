#requires -version 5.1
# Cline global hook: agent_abort -> ntfy notification.
# ASCII-only on purpose (see _notify.ps1 header).
$ErrorActionPreference = 'SilentlyContinue'
try {
    & (Join-Path $PSScriptRoot '_notify.ps1') -EventName 'agent_abort'
} catch {
}
exit 0
