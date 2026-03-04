# RunTests.ps1 - Test NuGet packages locally
# Usage: .\RunTests.ps1
# Requires: dotnet SDK, MSBuild (Visual Studio)

$ErrorActionPreference = "Stop"
$rootDir = $PSScriptRoot
$testDir = Join-Path $rootDir "TestProjects"
$packagesDir = Join-Path $rootDir "Packages"
$msbuild = $null

# Find MSBuild
$vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vsWhere)) {
    $vsWhere = "${env:ProgramFiles}\Microsoft Visual Studio\Installer\vswhere.exe"
}
if (Test-Path $vsWhere) {
    $installPath = & $vsWhere -latest -property installationPath
    $msbuild = Get-ChildItem "$installPath\MSBuild" -Recurse -Filter 'MSBuild.exe' | Where-Object { $_.FullName -match '\\Current\\' } | Select-Object -First 1
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " NuGet Package Test Runner" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $packagesDir) -or (Get-ChildItem $packagesDir -Filter '*.nupkg').Count -eq 0) {
    Write-Host "ERROR: No packages found in $packagesDir" -ForegroundColor Red
    Write-Host "Run Build.ps1 first to generate packages." -ForegroundColor Yellow
    exit 1
}

$allPassed = $true

# ============================================
# Test 1: C# SDK-style project
# ============================================
Write-Host "=== Test 1: C# SDK (.NET 8, win-x64) ===" -ForegroundColor Yellow
$sdkDir = Join-Path $testDir "TestCSharpSdk"

# Clean
Remove-Item -Recurse -Force (Join-Path $sdkDir "bin"), (Join-Path $sdkDir "obj") -ErrorAction SilentlyContinue

Write-Host "  Restoring..."
dotnet restore --no-cache $sdkDir 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "  FAIL: restore" -ForegroundColor Red; $allPassed = $false } 
else {
    Write-Host "  Building..."
    dotnet build --no-restore $sdkDir -c Debug 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "  FAIL: build" -ForegroundColor Red; $allPassed = $false }
    else {
        Write-Host "  Running..."
        $output = dotnet run --no-build --project $sdkDir -c Debug 2>&1
        $missing = $output | Select-String "MISSING!"
        if ($missing) {
            Write-Host "  FAIL: missing native files" -ForegroundColor Red
            $output | ForEach-Object { Write-Host "    $_" }
            $allPassed = $false
        } else {
            Write-Host "  PASS: All native files present" -ForegroundColor Green
        }
    }
}
Write-Host ""

# ============================================
# Test 2: C# .NET Framework project
# ============================================
Write-Host "=== Test 2: C# .NET Framework (4.7.2, x64) ===" -ForegroundColor Yellow
$fwDir = Join-Path $testDir "TestCSharpFramework"

if (-not $msbuild) {
    Write-Host "  SKIP: MSBuild not found (Visual Studio required)" -ForegroundColor DarkYellow
} else {
    # Clean
    Remove-Item -Recurse -Force (Join-Path $fwDir "bin"), (Join-Path $fwDir "obj") -ErrorAction SilentlyContinue

    Write-Host "  Building (MSBuild + restore)..."
    $buildOutput = & $msbuild.FullName "$fwDir\TestCSharpFramework.csproj" /t:Build /p:Configuration=Debug /p:Platform=x64 /restore /p:RestoreNoCache=true /v:minimal 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAIL: build" -ForegroundColor Red
        $buildOutput | ForEach-Object { Write-Host "    $_" }
        $allPassed = $false
    } else {
        Write-Host "  Running..."
        $output = & "$fwDir\bin\Debug\TestCSharpFramework.exe" 2>&1
        $missing = $output | Select-String "MISSING!"
        if ($missing) {
            Write-Host "  FAIL: missing native files (.targets copy failed)" -ForegroundColor Red
            $output | ForEach-Object { Write-Host "    $_" }
            $allPassed = $false
        } else {
            Write-Host "  PASS: All native files copied via .targets" -ForegroundColor Green
        }
    }
}
Write-Host ""

# ============================================
# Test 3: C++ project
# ============================================
Write-Host "=== Test 3: C++ vcxproj (x64, MSVC) ===" -ForegroundColor Yellow
$cppDir = Join-Path $testDir "TestCpp"

if (-not $msbuild) {
    Write-Host "  SKIP: MSBuild not found (Visual Studio required)" -ForegroundColor DarkYellow
} else {
    # Clean
    Remove-Item -Recurse -Force (Join-Path $cppDir "x64"), (Join-Path $cppDir "Debug"), (Join-Path $cppDir "obj") -ErrorAction SilentlyContinue

    Write-Host "  Restoring..."
    & $msbuild.FullName "$cppDir\TestCpp.vcxproj" /t:Restore /p:Platform=x64 /p:RestoreNoCache=true /v:minimal 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { 
        Write-Host "  FAIL: restore" -ForegroundColor Red; $allPassed = $false 
    } else {
        Write-Host "  Building..."
        $buildOutput = & $msbuild.FullName "$cppDir\TestCpp.vcxproj" /t:Build /p:Configuration=Debug /p:Platform=x64 /v:minimal 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  FAIL: build (headers/libs not found)" -ForegroundColor Red
            $buildOutput | ForEach-Object { Write-Host "    $_" }
            $allPassed = $false
        } else {
            Write-Host "  PASS: Compiled and linked successfully" -ForegroundColor Green
        }
    }
}
Write-Host ""

# ============================================
# Summary
# ============================================
Write-Host "========================================" -ForegroundColor Cyan
if ($allPassed) {
    Write-Host " ALL TESTS PASSED" -ForegroundColor Green
} else {
    Write-Host " SOME TESTS FAILED" -ForegroundColor Red
}
Write-Host "========================================" -ForegroundColor Cyan
