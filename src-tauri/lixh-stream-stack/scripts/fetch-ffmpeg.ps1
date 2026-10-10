# Fetch LiveCatchFfmpeg SDK and/or runtime for one platform (Windows-friendly).
# Usage:
#   .\fetch-ffmpeg.ps1 windows-x64
#   .\fetch-ffmpeg.ps1 android-arm64 -SdkOnly
#   .\fetch-ffmpeg.ps1 ios-arm64 -RuntimeOnly
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet('windows-x64', 'macos-arm64', 'macos-x64', 'android-arm64', 'ios-arm64')]
  [string]$Platform,
  [switch]$SdkOnly,
  [switch]$RuntimeOnly
)

$ErrorActionPreference = 'Stop'
$Version = if ($env:LIXH_FFMPEG_VERSION) { $env:LIXH_FFMPEG_VERSION } else { '9.0.2' }
$Repo = if ($env:LIXH_FFMPEG_REPO) { $env:LIXH_FFMPEG_REPO } else { 'xinghunbuxiu/LiveCatchFfmpeg' }
$Tag = if ($env:LIXH_FFMPEG_TAG) { $env:LIXH_FFMPEG_TAG } else { "ffmpeg-$Version-lc1" }
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$Stack = Join-Path $Root 'src-tauri\lixh-stream-stack'
$Base = "https://github.com/$Repo/releases/download/$Tag"

function Get-Zip($Asset, $OutDir) {
  $url = "$Base/$Asset"
  $tmp = Join-Path $env:TEMP $Asset
  Write-Host "GET $url"
  $ok = $false
  foreach ($i in 1..5) {
    try {
      Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 120
      $ok = $true
      break
    } catch {
      Write-Warning "attempt $i failed: $($_.Exception.Message)"
      Start-Sleep -Seconds (2 * $i)
    }
  }
  if (-not $ok) { throw "download failed: $Asset" }
  if (Test-Path $OutDir) { Remove-Item -Recurse -Force $OutDir }
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  Expand-Archive -Path $tmp -DestinationPath $OutDir -Force
  Remove-Item -Force $tmp -ErrorAction SilentlyContinue
  Write-Host "OK -> $OutDir"
}

$doSdk = -not $RuntimeOnly
$doRt = -not $SdkOnly
if ($doSdk) {
  Get-Zip "LiveCatch-ffmpeg-sdk-$Version-$Platform.zip" (Join-Path $Stack "sdk\$Platform")
}
if ($doRt) {
  Get-Zip "LiveCatch-ffmpeg-$Version-$Platform.zip" (Join-Path $Stack "runtime\$Platform")
}
