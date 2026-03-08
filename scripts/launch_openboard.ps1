$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$releaseExe = Join-Path $repoRoot 'build\windows\x64\runner\Release\openboard.exe'

function Test-BuildIsCurrent {
    param(
        [string]$ExecutablePath,
        [string]$ProjectRoot
    )

    if (-not (Test-Path $ExecutablePath)) {
        return $false
    }

    $exeTimestamp = (Get-Item $ExecutablePath).LastWriteTimeUtc
    $sourceTargets = @(
        (Join-Path $ProjectRoot 'pubspec.yaml'),
        (Join-Path $ProjectRoot 'lib'),
        (Join-Path $ProjectRoot 'windows')
    )

    foreach ($target in $sourceTargets) {
        if (-not (Test-Path $target)) {
            continue
        }

        $items = if ((Get-Item $target).PSIsContainer) {
            Get-ChildItem $target -Recurse -File
        } else {
            Get-Item $target
        }

        if ($items | Where-Object { $_.LastWriteTimeUtc -gt $exeTimestamp } | Select-Object -First 1) {
            return $false
        }
    }

    return $true
}

if (Test-BuildIsCurrent -ExecutablePath $releaseExe -ProjectRoot $repoRoot) {
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
