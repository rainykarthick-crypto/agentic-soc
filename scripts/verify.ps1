<#
.SYNOPSIS
    Verify the standalone Agentic SOC is running and correctly wired.
.DESCRIPTION
    Prints PASS/FAIL per check and exits non-zero if any check fails.
#>
[CmdletBinding()]
param(
    [string]$Dashboard = 'http://127.0.0.1:3010',
    [string]$Agent = 'http://127.0.0.1:8020'
)

$ErrorActionPreference = 'Continue'
$results = @()

function Check([string]$name, [bool]$pass, [string]$detail) {
    $script:results += [pscustomobject]@{ Name = $name; Pass = $pass; Detail = $detail }
}

function Running([string]$c) {
    return ((& docker inspect -f '{{.State.Running}}' $c 2>$null) -eq 'true')
}

Write-Host ''
Write-Host 'Agentic SOC - verification'
Write-Host ('=' * 68)

# ---------------------------------------------------------------- containers
foreach ($c in @('soc-agent', 'soc-dashboard')) {
    Check "$c running" (Running $c) $(if (Running $c) { 'up' } else { 'not running' })
}

# ------------------------------------------------------------------ agent API
# uvicorn with --reload needs a few seconds after a recreate, so poll instead of
# judging on the first attempt.
function Get-Json {
    param([string]$Url, [int]$Attempts = 20)
    for ($i = 0; $i -lt $Attempts; $i++) {
        try { return (Invoke-WebRequest -Uri $Url -TimeoutSec 3 -UseBasicParsing).Content | ConvertFrom-Json }
        catch { Start-Sleep -Milliseconds 1500 }
    }
    return $null
}

$h = Get-Json "$Agent/health"
if ($h) {
    Check 'agent /health' ($h.status -eq 'ok') ("model=" + $h.model)
} else {
    Check 'agent /health' $false 'no response after 30s'
}

# ------------------------------------------------------------------- console
try {
    $page = (Invoke-WebRequest -Uri "$Dashboard/" -TimeoutSec 8 -UseBasicParsing).Content
    Check 'console serves the dashboard' ($page -match 'Activity timeline') 'index.html'
    Check 'console has no external asset tags' (-not ($page -match 'cdnjs|unpkg|jsdelivr|googleapis')) 'self-contained'
} catch {
    Check 'console serves the dashboard' $false $_.Exception.Message
}

# ------------------------------------------------------------- /api proxy
$s = Get-Json "$Dashboard/api/status"
if ($s) {
    Check 'console proxies /api to the agent' ($null -ne $s.state) ("state=" + $s.state)
} else {
    Check 'console proxies /api to the agent' $false 'no response from /api/status'
}

$t = Get-Json "$Dashboard/api/tools"
if ($t) {
    Check 'tool registry reachable' ($t.tools.Count -gt 0) ($t.tools.Count.ToString() + ' tools')
} else {
    Check 'tool registry reachable' $false 'no response from /api/tools'
}

# -------------------------------------------------------------------- patches
if (Running 'soc-agent') {
    $timeoutOk = (& docker exec soc-agent grep -c 'timeout=900.0' /app/main.py 2>$null)
    Check 'LLM timeout patch applied' ($timeoutOk -match '^[1-9]') 'timeout=900.0 in /app/main.py'

    # Match without embedded quotes: PowerShell's native-argument handling strips
    # them, which silently turned this check into a failure.
    $urlOk = (& docker exec soc-agent grep -c 'os.environ.get' /app/main.py 2>$null)
    Check 'Ollama URL is configurable' ($urlOk -match '^[1-9]') 'reads OLLAMA_URL from the environment'
} else {
    Check 'LLM timeout patch applied' $false 'agent not running'
    Check 'Ollama URL is configurable' $false 'agent not running'
}

# ---------------------------------------------------------------------- ports
$ids = & docker compose -f (Join-Path (Split-Path -Parent $PSScriptRoot) 'docker-compose.yml') ps -q 2>$null
if ($ids) {
    $all = @()
    foreach ($id in $ids) { $all += (& docker port $id 2>$null) }
    $published = $all | Where-Object { $_ -and $_ -match '->' }
    $bad = $published | Where-Object { $_ -notmatch '->\s*127\.0\.0\.1:' }
    Check 'all published ports are loopback only' ($bad.Count -eq 0) ($(if ($bad) { $bad -join '; ' } else { 'ok' }))
} else {
    Check 'all published ports are loopback only' $false 'no running containers'
}

# --------------------------------------------------------------------- report
Write-Host ''
$results | ForEach-Object {
    $tag = if ($_.Pass) { 'PASS' } else { 'FAIL' }
    $col = if ($_.Pass) { 'Green' } else { 'Red' }
    Write-Host ("  {0}  {1,-38} {2}" -f $tag, $_.Name, $_.Detail) -ForegroundColor $col
}

$failed = ($results | Where-Object { -not $_.Pass }).Count
Write-Host ''
if ($failed -eq 0) {
    Write-Host "All $($results.Count) checks passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "$failed of $($results.Count) checks failed." -ForegroundColor Red
    exit 1
}
