# ============================================================================
# Slate - one-shot installer build.
#   Rust core -> obfuscated Flutter release -> stage VC++ runtime ->
#   Inno Setup -> Releases\Slate_Setup_v<ver>.exe
# Version is read from pubspec.yaml (single source). Run from anywhere.
# NOTE: kept pure ASCII on purpose - PowerShell 5.1 reads a BOM-less .ps1 as
# ANSI, so box-drawing / em-dash chars corrupt the parse.
# ============================================================================
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent   # project root (tools\ is one level down)

function Step($n) { Write-Host "`n=== $n ===" -ForegroundColor Cyan }

# cargo, flutter and ISCC all write ordinary progress and warnings to stderr.
# Under $ErrorActionPreference='Stop' PowerShell can turn that into a
# TERMINATING error and the build dies on a `warning:` line having produced
# nothing - it bit us on 2026-08-06 when the script was invoked with a `2>&1`
# redirect. Judge a native tool by its EXIT CODE, never by whether it spoke on
# stderr.
function Invoke-Native([string]$what, [scriptblock]$cmd) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $cmd } finally { $ErrorActionPreference = $prev }
  if ($LASTEXITCODE -ne 0) { throw "$what failed (exit $LASTEXITCODE)" }
}

# -- Version from pubspec (1.1.3+12 -> 1.1.3) --------------------------------
$verLine = Select-String -Path "$root\pubspec.yaml" -Pattern '^version:\s*(.+)$' | Select-Object -First 1
if (-not $verLine) { throw "version: not found in pubspec.yaml" }
$version = ($verLine.Matches[0].Groups[1].Value.Trim() -split '\+')[0]
Write-Host "Slate version: $version" -ForegroundColor White

# -- ISCC (Inno Setup) location ----------------------------------------------
$iscc = @(
  "$env:LocalAppData\Programs\Inno Setup 6\ISCC.exe",
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw "ISCC.exe not found. Install: winget install JRSoftware.InnoSetup" }
Write-Host "ISCC: $iscc" -ForegroundColor White

# -- 1. Rust core (release) + DLL to project root (the DLL law) ---------------
Step "1/5  Rust core (cargo build --release)"
Push-Location "$root\native"
try { Invoke-Native "cargo build" { cargo build --release } } finally { Pop-Location }
Copy-Item "$root\native\target\release\slate_core.dll" "$root\slate_core.dll" -Force
Write-Host "  slate_core.dll -> project root" -ForegroundColor Green

# -- 2. Flutter release (NO obfuscation - avoids false-positive AV flags) -----
# Obfuscation was removed in v1.1.8 because --obfuscate triggers heuristic
# detections (Wacatac.B!ml, ObfuscatedPoly) on VirusTotal.  For a desktop app
# distributed directly, Dart AOT already compiles to native x64 - obfuscation
# adds negligible reverse-engineering protection but costs 4+ AV false positives.
Step "2/5  flutter build windows --release"
Push-Location $root
try {
  Invoke-Native "flutter build" {
    & flutter build windows --release
  }
} finally { Pop-Location }
$release = "$root\build\windows\x64\runner\Release"
if (-not (Test-Path "$release\slate.exe")) { throw "release build missing: $release\slate.exe" }

# -- 3. Stage app-local VC++ runtime next to slate.exe -----------------------
Step "3/5  Stage VC++ runtime (app-local)"
$vc = @('msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll')
foreach ($d in $vc) {
  $srcSys = Join-Path $env:SystemRoot "System32\$d"
  if (Test-Path $srcSys) {
    Copy-Item $srcSys (Join-Path $release $d) -Force
    Write-Host "  + $d" -ForegroundColor Green
  } else {
    Write-Warning "  $d NOT FOUND in System32. Clean tester machines may fail to launch; install the VC++ 2015-2022 x64 redist on this build machine."
  }
}

# -- 4. Compile the installer ------------------------------------------------
Step "4/6  Inno Setup (ISCC)"
Invoke-Native "ISCC" { & $iscc "/DMyAppVersion=$version" "$root\installer\slate.iss" }
$setup = "$root\Releases\Slate_Setup_v$version.exe"
if (-not (Test-Path $setup)) { throw "installer not produced: $setup" }

# -- 5. Archive the raw bundle (DEPLOYS.md law) -------------------------------
# Done here, not by hand: v1.1.4 has no folder in Releases because the manual
# copy was simply forgotten.
Step "5/6  Archive bundle -> Releases\slate_v$version"
$bundle = "$root\Releases\slate_v$version"
if (Test-Path $bundle) { Remove-Item $bundle -Recurse -Force }
Copy-Item $release $bundle -Recurse -Force
if (-not (Test-Path "$bundle\slate.exe")) { throw "bundle copy failed: $bundle" }
Write-Host "  bundle -> $bundle" -ForegroundColor Green

# -- 6. Done -----------------------------------------------------------------
Step "6/6  Done"
$mb = [math]::Round((Get-Item $setup).Length / 1MB, 1)
Write-Host "  OUTPUT: $setup  ($mb MB)" -ForegroundColor Green
Write-Host "  BUNDLE: $bundle" -ForegroundColor Green
Write-Host ""
Write-Host "NEXT: refresh the stable-name copy the landing page links to:" -ForegroundColor Yellow
Write-Host "      Copy-Item '$setup' '$root\Releases\Slate_Setup.exe' -Force" -ForegroundColor Yellow
Write-Host "NEXT: run the setup through https://www.virustotal.com before sharing." -ForegroundColor Yellow
Write-Host "      (global hotkey + HKCU autostart + DLLs look like spyware to AV heuristics;" -ForegroundColor Yellow
Write-Host "       submit free false-positive reports to any vendor that flags it.)" -ForegroundColor Yellow
Write-Host "      Unsigned: testers see SmartScreen, use 'More info' then 'Run anyway'." -ForegroundColor Yellow
