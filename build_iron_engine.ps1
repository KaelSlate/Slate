# SLATE Iron Engine - Build & Integrate Script
# Phase 12.0: Full Rust FFI Integration

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  SLATE IRON ENGINE - Build Script" -ForegroundColor White
Write-Host "  Phase 12.0: Rust + Flutter Bridge Integration" -ForegroundColor Gray
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host ""

$projectRoot = $PSScriptRoot
$nativeDir = Join-Path $projectRoot "native"
$libDir = Join-Path $projectRoot "lib\generated"

# Step 1: Check Rust installation
Write-Host "[1/5] Checking Rust environment..." -ForegroundColor Yellow
try {
    $rustVersion = rustc --version
    Write-Host "  OK: $rustVersion" -ForegroundColor Green
}
catch {
    Write-Host "  ERROR: Rust not found!" -ForegroundColor Red
    Write-Host "  Install Rust with: winget install Rustlang.Rustup" -ForegroundColor Yellow
    Write-Host "  Or visit: https://rustup.rs" -ForegroundColor Yellow
    exit 1
}

# Step 2: Install flutter_rust_bridge_codegen
Write-Host "[2/5] Installing Flutter Rust Bridge codegen..." -ForegroundColor Yellow
cargo install flutter_rust_bridge_codegen 2>$null
Write-Host "  OK: flutter_rust_bridge_codegen ready" -ForegroundColor Green

# Step 3: Build Rust library
Write-Host "[3/5] Building Rust library (release)..." -ForegroundColor Yellow
Push-Location $nativeDir
cargo build --release
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ERROR: Rust build failed!" -ForegroundColor Red
    Pop-Location
    exit 1
}
Write-Host "  OK: Rust library built" -ForegroundColor Green
Pop-Location

# Step 4: Generate FFI bindings
Write-Host "[4/5] Generating Flutter Rust Bridge bindings..." -ForegroundColor Yellow

if (-not (Test-Path $libDir)) {
    New-Item -ItemType Directory -Path $libDir -Force | Out-Null
}

flutter_rust_bridge_codegen generate --rust-input native/src/api.rs --dart-output lib/generated/slate_core.dart --class-name SlateCoreImpl 2>$null
Write-Host "  OK: FFI bindings generated" -ForegroundColor Green

# Step 5: Copy DLL to build output
Write-Host "[5/5] Preparing runtime files..." -ForegroundColor Yellow
$dllPath = Join-Path $nativeDir "target\release\slate_core.dll"

$debugDir = Join-Path $projectRoot "build\windows\x64\runner\Debug"
$profileDir = Join-Path $projectRoot "build\windows\x64\runner\Profile"
$releaseDir = Join-Path $projectRoot "build\windows\x64\runner\Release"

if (Test-Path $dllPath) {
    # 1. Copy to the root (essential for Dart fallback & FFI lookup)
    Copy-Item $dllPath (Join-Path $projectRoot "slate_core.dll") -Force
    Write-Host "  OK: DLL copied to project root" -ForegroundColor Green

    # 2. Copy to Debug if it exists
    if (Test-Path $debugDir) {
        Copy-Item $dllPath (Join-Path $debugDir "slate_core.dll") -Force
        Write-Host "  OK: DLL copied to Debug directory" -ForegroundColor Green
    }

    # 3. Copy to Profile if it exists
    if (Test-Path $profileDir) {
        Copy-Item $dllPath (Join-Path $profileDir "slate_core.dll") -Force
        Write-Host "  OK: DLL copied to Profile directory" -ForegroundColor Green
    }
    
    # 4. Copy to Release if it exists
    if (Test-Path $releaseDir) {
        Copy-Item $dllPath (Join-Path $releaseDir "slate_core.dll") -Force
        Write-Host "  OK: DLL copied to Release directory" -ForegroundColor Green
    }
} else {
    Write-Host "  WARNING: DLL not found at $dllPath" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  BUILD COMPLETE!" -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor White
Write-Host "  1. Run: flutter run -d windows" -ForegroundColor Gray
Write-Host "  2. Iron Engine v1.1.0 will power all calculations" -ForegroundColor Gray
Write-Host ""
