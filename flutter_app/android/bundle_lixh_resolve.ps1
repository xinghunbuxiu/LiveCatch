# Cross-compile stream-stack lixh_resolve for Android arm64 and stage as jniLibs.
# Usage (from repo root or anywhere):
#   pwsh flutter_app/android/bundle_lixh_resolve.ps1
param(
  [string]$NdkRoot = $env:ANDROID_NDK_HOME,
  [string]$ApiLevel = "26"
)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$stack = Join-Path $repo "src-tauri\lixh-stream-stack"
$outBin = Join-Path $stack "target\aarch64-linux-android\release\lixh_resolve"
$jniDir = Join-Path $PSScriptRoot "app\src\main\jniLibs\arm64-v8a"
$jniSo = Join-Path $jniDir "liblixh_resolve.so"

if (-not $NdkRoot -or -not (Test-Path $NdkRoot)) {
  $sdk = $env:ANDROID_SDK_ROOT
  if (-not $sdk) { $sdk = $env:ANDROID_HOME }
  if (-not $sdk) { $sdk = "C:\Users\admin\tools\Android\Sdk" }
  $ndkParent = Join-Path $sdk "ndk"
  if (Test-Path $ndkParent) {
    $NdkRoot = (Get-ChildItem $ndkParent -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
  }
}
if (-not $NdkRoot -or -not (Test-Path $NdkRoot)) {
  throw "ANDROID_NDK_HOME / NDK not found"
}

$prebuilt = (Get-ChildItem (Join-Path $NdkRoot "toolchains\llvm\prebuilt") -Directory | Select-Object -First 1).FullName
$clang = Join-Path $prebuilt "bin\aarch64-linux-android${ApiLevel}-clang.cmd"
if (-not (Test-Path $clang)) {
  $clang = Join-Path $prebuilt "bin\aarch64-linux-android${ApiLevel}-clang"
}
$ar = Join-Path $prebuilt "bin\llvm-ar.exe"
if (-not (Test-Path $clang)) { throw "NDK clang missing: $clang" }

$env:ANDROID_NDK_HOME = $NdkRoot
$env:ANDROID_NDK_ROOT = $NdkRoot
$env:CC_aarch64_linux_android = $clang
$env:AR_aarch64_linux_android = $ar
$env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER = $clang
if (-not $env:PROTOC -and (Test-Path "C:\Users\admin\tools\protoc\bin\protoc.exe")) {
  $env:PROTOC = "C:\Users\admin\tools\protoc\bin\protoc.exe"
}

Write-Host "NDK=$NdkRoot"
Write-Host "Building lixh_resolve (aarch64-linux-android)…"
Push-Location $stack
try {
  cargo build -p lixh-stream-resolver --bin lixh_resolve --release --target aarch64-linux-android
  if ($LASTEXITCODE -ne 0) { throw "cargo build failed: $LASTEXITCODE" }
} finally {
  Pop-Location
}

if (-not (Test-Path $outBin)) { throw "Missing $outBin" }
New-Item -ItemType Directory -Force -Path $jniDir | Out-Null
Copy-Item -Force $outBin $jniSo
Write-Host "Staged $jniSo ($([math]::Round((Get-Item $jniSo).Length/1MB,1)) MB)"
