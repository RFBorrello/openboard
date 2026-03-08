$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$releaseExe = Join-Path $repoRoot 'build\windows\x64\runner\Release\openboard.exe'

if (Test-Path $releaseExe) {
    Start-Process -FilePath $releaseExe | Out-Null
    exit 0
}

$flutter = Get-Command flutter -ErrorAction SilentlyContinue
if (-not $flutter) {
    Write-Error 'Flutter is not installed or not available on PATH. Build OpenBoard once, or install Flutter first.'
}

Push-Location $repoRoot
try {
    & flutter build windows
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
} finally {
    Pop-Location
}

if (-not (Test-Path $releaseExe)) {
    Write-Error 'OpenBoard build completed without producing the Windows executable.'
}

Start-Process -FilePath $releaseExe | Out-Null
