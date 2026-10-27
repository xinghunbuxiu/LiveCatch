# Build LiveCatch Windows release with RewardPlay dart-defines.
# Requires: Flutter Windows desktop, MSVC, optional Inno Setup 6.
#
# Usage (from repo root or flutter_app):
#   pwsh flutter_app/windows/build_release.ps1
#   pwsh flutter_app/windows/build_release.ps1 -SkipInstaller
#
# Reads flutter_app/.env.rewardplay.local (JSON dart-define-from-file). Example:
#   {
#     "REWARDPLAY_BASE_URL": "http://101.35.40.114",
#     "REWARDPLAY_PROJECT_CODE": "LIVE_CATCH",
#     "REWARDPLAY_INTEGRATION_TOKEN": "rpt_..."
#   }

[CmdletBinding()]
param(
    [switch]$SkipInstaller,
    [switch]$SkipDistCopy
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$FlutterApp = Resolve-Path (Join-Path $ScriptDir "..")
$RepoRoot = Resolve-Path (Join-Path $FlutterApp "..")
$EnvFile = Join-Path $FlutterApp ".env.rewardplay.local"
$ReleaseDir = Join-Path $FlutterApp "build\windows\x64\runner\Release"
$InstallerDir = Join-Path $FlutterApp "build\windows\installer"
$DistDir = Join-Path $RepoRoot "dist"

if (-not (Test-Path $EnvFile)) {
    throw "Missing $EnvFile — copy the RewardPlay JSON dart-define file first."
}

$defines = Get-Content -Raw -Path $EnvFile | ConvertFrom-Json
$token = [string]$defines.REWARDPLAY_INTEGRATION_TOKEN
if ([string]::IsNullOrWhiteSpace($token)) {
    throw "REWARDPLAY_INTEGRATION_TOKEN is empty in $EnvFile"
}
Write-Host "RewardPlay defines OK (token length=$($token.Length), project=$($defines.REWARDPLAY_PROJECT_CODE))"

Push-Location $FlutterApp
try {
    flutter pub get
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    flutter build windows --release --dart-define-from-file=".env.rewardplay.local"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $exe = Join-Path $ReleaseDir "livecatch_app.exe"
    if (-not (Test-Path $exe)) {
        throw "Windows release output missing: $exe"
    }

    & (Join-Path $ScriptDir "installer\bundle-msvc-crt.ps1") -DestDir $ReleaseDir
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $verLine = (Get-Content (Join-Path $FlutterApp "pubspec.yaml") | Select-String '^version:').Line
    $version = ($verLine -split ':', 2)[1].Trim().Split('+')[0]

    if (-not $SkipInstaller) {
        New-Item -ItemType Directory -Force -Path $InstallerDir | Out-Null
        $iscc = $null
        foreach ($cand in @(
            "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
            "C:\Program Files\Inno Setup 6\ISCC.exe"
        )) {
            if (Test-Path $cand) { $iscc = $cand; break }
        }
        if (-not $iscc) {
            $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
            if ($cmd) { $iscc = $cmd.Source }
        }
        if (-not $iscc) {
            Write-Warning "Inno Setup not found; skipping installer. Release folder: $ReleaseDir"
        } else {
            # Inno Setup 6: /DName=Value ; Inno Setup 7+: --define=Name=Value
            $isccVer = & $iscc --version 2>$null
            $useIs7 = ($isccVer -match '^7\.')
            $iss = Join-Path $ScriptDir "installer\LiveCatch.iss"
            if ($useIs7) {
                & $iscc $iss `
                    "--define=MyAppVersion=$version" `
                    "--define=SourceDir=$ReleaseDir" `
                    "--define=OutputDir=$InstallerDir"
            } else {
                & $iscc $iss `
                    "/DMyAppVersion=$version" `
                    "/DSourceDir=$ReleaseDir" `
                    "/DOutputDir=$InstallerDir"
            }
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        }
    }

    if (-not $SkipDistCopy) {
        New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
        $portableZip = Join-Path $DistDir "LiveCatch-windows-x64-portable.zip"
        if (Test-Path $portableZip) { Remove-Item -Force $portableZip }
        Compress-Archive -Path (Join-Path $ReleaseDir "*") -DestinationPath $portableZip -Force
        Write-Host "Wrote $portableZip"

        $setup = Get-ChildItem $InstallerDir -Filter "*-setup.exe" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($setup) {
            $destSetup = Join-Path $DistDir $setup.Name
            Copy-Item -Force $setup.FullName $destSetup
            # Keep a stable alias used by older docs / dist layout.
            Copy-Item -Force $setup.FullName (Join-Path $DistDir "LiveCatch-$version-windows-x64-setup.exe")
            Write-Host "Wrote $destSetup"
        }
    }

    Write-Host "Done. Release: $ReleaseDir"
}
finally {
    Pop-Location
}
