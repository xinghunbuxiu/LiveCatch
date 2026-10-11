# Copy MSVC VC143 CRT DLLs next to the app (app-local deployment).
# Avoids "VCRUNTIME140.dll was not found" on machines without VC++ Redistributable.
param(
  [Parameter(Mandatory = $true)]
  [string]$DestDir
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $DestDir)) {
  throw "DestDir does not exist: $DestDir"
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
$crtDir = $null

# Prefer desktop CRT (...\MSVC\<ver>\x64\Microsoft.VC143.CRT), never onecore.
function Select-DesktopVc143CrtDir([string[]]$Markers) {
  $dirs = $Markers |
    Where-Object { $_ } |
    ForEach-Object { Split-Path -Parent $_ } |
    Where-Object { $_ -match '[\\/]MSVC[\\/][^\\/]+[\\/]x64[\\/]Microsoft\.VC143\.CRT$' -and $_ -notmatch '[\\/]onecore[\\/]' } |
    Sort-Object -Descending |
    Select-Object -First 1
  return $dirs
}

if (Test-Path -LiteralPath $vswhere) {
  $markers = @(& $vswhere -latest -products * -find "**/Microsoft.VC143.CRT/vcruntime140.dll")
  $crtDir = Select-DesktopVc143CrtDir $markers
}

if (-not $crtDir) {
  $candidates = @(
    "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Redist\MSVC\*\x64\Microsoft.VC143.CRT"
    "C:\Program Files\Microsoft Visual Studio\2022\*\VC\Redist\MSVC\*\x64\Microsoft.VC143.CRT"
    "C:\Program Files (x86)\Microsoft Visual Studio\2022\*\VC\Redist\MSVC\*\x64\Microsoft.VC143.CRT"
  )
  foreach ($pattern in $candidates) {
    $hit = Get-Item $pattern -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -notmatch '[\\/]onecore[\\/]' } |
      Sort-Object FullName -Descending |
      Select-Object -First 1
    if ($hit) {
      $crtDir = $hit.FullName
      break
    }
  }
}

if (-not $crtDir -or -not (Test-Path -LiteralPath $crtDir)) {
  throw "Microsoft.VC143.CRT (x64) not found. Install VS Build Tools with C++ redistributables."
}

$required = @(
  "msvcp140.dll"
  "vcruntime140.dll"
  "vcruntime140_1.dll"
)
foreach ($name in $required) {
  if (-not (Test-Path -LiteralPath (Join-Path $crtDir $name))) {
    throw "Missing required CRT DLL: $crtDir\$name"
  }
}

Copy-Item -Path (Join-Path $crtDir "*.dll") -Destination $DestDir -Force
$copied = Get-ChildItem -LiteralPath $DestDir -Filter "*.dll" |
  Where-Object { $_.Name -match '^(msvcp140|vcruntime140|concrt140|vccorlib140)' }
Write-Host "Bundled MSVC CRT from: $crtDir"
$copied | ForEach-Object { Write-Host "  $($_.Name) ($([math]::Round($_.Length/1KB)) KB)" }
