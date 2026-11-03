<#
.SYNOPSIS
    Provision and run the standalone Agentic SOC.

.DESCRIPTION
    Clones the upstream agent, applies three local patches, and optionally builds,
    starts and verifies the stack.

.PARAMETER Build
    Build the two images.

.PARAMETER Up
    Start the stack after (optional) build.

.PARAMETER Verify
    Run verification checks.

.EXAMPLE
    .\setup.ps1 -Build -Up -Verify
#>
[CmdletBinding()]
param(
    [switch]$Build,
    [switch]$Up,
    [switch]$Verify
)

$ErrorActionPreference = 'Stop'
$Root     = Split-Path -Parent $PSScriptRoot
$Compose  = Join-Path $Root 'docker-compose.yml'
$EnvFile  = Join-Path $Root '.env'
$AgentSrc = Join-Path $Root 'vendor\Agentic-SOC\agent'

function Step($t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "   [ok]   $t" -ForegroundColor Green }
function Info($t) { Write-Host "   $t" }

# ---------------------------------------------------------------- 1 preflight
Step '1/5 Preflight'

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'docker is not on PATH.' }
& docker info --format '{{.ServerVersion}}' *> $null
if ($LASTEXITCODE -ne 0) { throw 'Docker daemon is not running.' }
Ok "docker $(& docker --version)"

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git is required to clone the agent.' }
Ok 'git available'

foreach ($p in 3010, 8020) {
    if (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) {
        Write-Host "   [warn] port $p already in use" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------- 2 env
Step '2/5 Environment'
if (Test-Path $EnvFile) {
    Ok '.env already exists (left untouched)'
} else {
    Copy-Item (Join-Path $Root '.env.example') $EnvFile
    Ok '.env created from .env.example'
}

# ------------------------------------------------------------------- 3 vendor
Step '3/5 Agent source'
if (Test-Path (Join-Path $AgentSrc 'main.py')) {
    Ok 'agent already cloned'
} else {
    Info 'cloning Nnamdi10/Agentic-SOC ...'
    & git clone --depth 1 --quiet https://github.com/Nnamdi10/Agentic-SOC.git (Join-Path $Root 'vendor\Agentic-SOC')
    if ($LASTEXITCODE -ne 0) { throw 'clone failed' }
    Ok 'agent cloned'
}

# --------------------------------------------------------------- 4 patch code
Step '4/5 Local patches'

# Applied to the checkout, never to the upstream repository, and never copied
# into this repo (the upstream project has no license file, so redistributing a
# fork of its source would be a licensing question).
#
#   1. import os                      - needed by patch 2
#   2. OLLAMA_URL from the environment - so this can share an existing model server
#   3. httpx timeout 60s -> 900s      - a reasoning reply needs 150s+ on a small CPU
$agentMain = Join-Path $AgentSrc 'main.py'
if (-not (Test-Path $agentMain)) { throw "missing $agentMain after clone" }

$text = [System.IO.File]::ReadAllText($agentMain)
$before = $text
$utf8 = New-Object System.Text.UTF8Encoding($false)

# A Windows clone keeps CRLF endings, so an anchor of "import json$" never
# matches (the line ends \r\n) and the import is silently skipped - leaving a
# call to os.environ with no `import os`. The \r? below makes this EOL-agnostic.
if (-not [regex]::IsMatch($text, '(?m)^import os\r?$')) {
    $text = [regex]::Replace($text, '(?m)^import json\r?$', { param($m) $m.Value + "`nimport os" })
}

$text = $text -replace 'OLLAMA_URL = "http://ollama:11434/api/generate"',
                         'OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://ollama:11434/api/generate")'

$text = $text -replace 'httpx\.AsyncClient\(timeout=60\.0\)',
                         'httpx.AsyncClient(timeout=900.0)'

# Fail loudly rather than building an image that cannot import.
if (-not [regex]::IsMatch($text, '(?m)^import os\r?$')) { throw 'failed to insert "import os"' }
if ($text -notmatch 'os\.environ\.get\("OLLAMA_URL"') { throw 'failed to make OLLAMA_URL configurable' }
if ($text -notmatch 'timeout=900\.0') { throw 'failed to raise the LLM timeout' }

if ($text -ne $before) {
    [System.IO.File]::WriteAllText($agentMain, $text, $utf8)
    Ok 'patched (os import, OLLAMA_URL env, 900s timeout)'
} else {
    Ok 'already patched'
}

# Prove the patched file is still valid Python before building on it.
$py = (Get-Command python -ErrorAction SilentlyContinue)
if ($py) {
    & $py.Source -c "import ast,sys; ast.parse(open(sys.argv[1],encoding='utf-8').read())" $agentMain
    if ($LASTEXITCODE -ne 0) { throw 'patched main.py is not valid Python' }
    Ok 'patched source parses'
}

# -------------------------------------------------------------------- 5 build
Step '5/5 Build, start, verify'

# Docker writes build progress to stderr. With $ErrorActionPreference = 'Stop',
# PowerShell 5.1 turns that into a terminating NativeCommandError and kills the
# script mid-build, so native calls run with it relaxed and are checked by exit
# code instead.
function Invoke-Docker {
    param([string[]]$DockerArgs)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # Out-Host keeps the command's own output off the pipeline; otherwise it
        # is captured together with the return value and $code becomes an array.
        & docker @DockerArgs | Out-Host
    } finally {
        $global:ErrorActionPreference = $previous
    }
    return $LASTEXITCODE
}

if ($Build) {
    $code = Invoke-Docker @('compose', '-f', $Compose, '--env-file', $EnvFile, 'build')
    if ($code -ne 0) { throw 'build failed' }
    Ok 'images built'
} else {
    Info 'skipped build (pass -Build)'
}

if ($Up) {
    $code = Invoke-Docker @('compose', '-f', $Compose, '--env-file', $EnvFile, 'up', '-d')
    if ($code -ne 0) { throw 'compose up failed' }
    Start-Sleep -Seconds 6
    Invoke-Docker @('compose', '-f', $Compose, '--env-file', $EnvFile, 'ps') | Out-Null
    Ok 'stack started'
} else {
    Info 'skipped start (pass -Up)'
}

if ($Verify) {
    & (Join-Path $PSScriptRoot 'verify.ps1')
} else {
    Info 'skipped verify (pass -Verify)'
}

Write-Host ''
Write-Host 'Console: http://127.0.0.1:3010' -ForegroundColor Cyan
Write-Host 'Agent:   http://127.0.0.1:8020/health' -ForegroundColor Cyan
