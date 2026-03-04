# RunTests.ps1 - Test NuGet packages locally
# Usage: .\RunTests.ps1
# Requires: dotnet SDK, MSBuild (Visual Studio) for Framework/C++ tests

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
$results = @()

function Test-PublishOutput {
    param(
        [string]$Name,
        [string]$ProjectDir,
        [string]$Rid,
        [string[]]$ExpectedFiles
    )

    Write-Host "=== $Name ===" -ForegroundColor Yellow
    $proj = Get-ChildItem $ProjectDir -Filter '*.csproj' | Select-Object -First 1

    # Clean
    Remove-Item -Recurse -Force (Join-Path $ProjectDir "bin"), (Join-Path $ProjectDir "obj") -ErrorAction SilentlyContinue

    Write-Host "  Restoring (--no-cache)..."
    $restoreOut = dotnet restore --no-cache $proj.FullName 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAIL: restore" -ForegroundColor Red
        $restoreOut | ForEach-Object { Write-Host "    $_" }
        return $false
    }

    Write-Host "  Publishing ($Rid)..."
    $pubDir = Join-Path $ProjectDir "bin\publish"
    $pubOut = dotnet publish --no-restore $proj.FullName -c Release -o $pubDir 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAIL: publish" -ForegroundColor Red
        $pubOut | ForEach-Object { Write-Host "    $_" }
        return $false
    }

    # Check expected files
    $allFound = $true
    foreach ($f in $ExpectedFiles) {
        $path = Join-Path $pubDir $f
        if (Test-Path $path) {
            Write-Host "  OK: $f" -ForegroundColor Green
        } else {
            Write-Host "  MISSING: $f" -ForegroundColor Red
            $allFound = $false
        }
    }

    if ($allFound) {
        Write-Host "  PASS" -ForegroundColor Green
    } else {
        Write-Host "  FAIL: some files missing" -ForegroundColor Red
    }
    Write-Host ""
    return $allFound
}

function Test-CppVcxproj {
    param(
        [string]$Name,
        [string]$ProjectDir,
        [string]$Platform,
        [bool]$Build
    )
    
    Write-Host "=== $Name ===" -ForegroundColor Yellow
    
    if (-not $msbuild) {
        Write-Host "  SKIP: MSBuild not found" -ForegroundColor DarkYellow
        return "SKIP"
    }
    
    $proj = Get-ChildItem $ProjectDir -Filter '*.vcxproj' | Select-Object -First 1
    
    Remove-Item -Recurse -Force (Join-Path $ProjectDir $Platform), (Join-Path $ProjectDir "Debug"), (Join-Path $ProjectDir "obj") -ErrorAction SilentlyContinue
    
    Write-Host "  Restoring ($Platform)..."
    $restoreOut = & $msbuild.FullName $proj.FullName /t:Restore /p:Platform=$Platform /p:RestoreNoCache=true /v:minimal 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAIL: restore" -ForegroundColor Red
        $restoreOut | ForEach-Object { Write-Host "    $_" }
        return "FAIL"
    }
    
    if ($Build) {
        Write-Host "  Building ($Platform)..."
        $buildOutput = & $msbuild.FullName $proj.FullName /t:Build /p:Configuration=Debug /p:Platform=$Platform /v:minimal 2>&1
        if ($LASTEXITCODE -ne 0) {
            $err = $buildOutput | Out-String
            if ($err -match "MSB8020") {
                Write-Host "  SKIP: Build tools for $Platform not installed (MSB8020)" -ForegroundColor DarkYellow
                return "SKIP (Missing Toolset)"
            } else {
                Write-Host "  FAIL: build" -ForegroundColor Red
                $buildOutput | ForEach-Object { Write-Host "    $_" }
                return "FAIL"
            }
        } else {
            Write-Host "  PASS: Compiled and linked" -ForegroundColor Green
            return "PASS"
        }
    } else {
        Write-Host "  PASS: Restored successfully" -ForegroundColor Green
        return "PASS (Restore Only)"
    }
}

# ============================================
# C# SDK Tests
# ============================================
Write-Host "=== Test 1: C# SDK win-x64 (build + run) ===" -ForegroundColor Yellow
$sdkDir = Join-Path $testDir "TestCSharpSdk.Win.x64"
Remove-Item -Recurse -Force (Join-Path $sdkDir "bin"), (Join-Path $sdkDir "obj") -ErrorAction SilentlyContinue

Write-Host "  Restoring (--no-cache)..."
dotnet restore --no-cache $sdkDir 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "  FAIL: restore" -ForegroundColor Red; $allPassed = $false; $results += "FAIL: C# SDK win-x64" }
else {
    Write-Host "  Building..."
    dotnet build --no-restore $sdkDir -c Debug 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "  FAIL: build" -ForegroundColor Red; $allPassed = $false; $results += "FAIL: C# SDK win-x64" }
    else {
        Write-Host "  Running..."
        $output = dotnet run --no-build --project $sdkDir -c Debug 2>&1
        $missing = $output | Select-String "MISSING!"
        if ($missing) {
            Write-Host "  FAIL: missing native files" -ForegroundColor Red
            $output | ForEach-Object { Write-Host "    $_" }
            $allPassed = $false; $results += "FAIL: C# SDK win-x64"
        } else {
            Write-Host "  PASS" -ForegroundColor Green
            $results += "PASS: C# SDK win-x64"
        }
    }
}
Write-Host ""

$r2 = Test-PublishOutput "Test 2: C# SDK win-arm64 (publish)" (Join-Path $testDir "TestCSharpSdk.Win.arm64") "win-arm64" @("avcodec-62.dll","avdevice-62.dll","avfilter-11.dll","avformat-62.dll","avutil-60.dll","swresample-6.dll","swscale-9.dll","ffmpeg.exe","ffplay.exe","ffprobe.exe")
if (-not $r2) { $allPassed = $false; $results += "FAIL: C# SDK win-arm64" } else { $results += "PASS: C# SDK win-arm64" }

$r3 = Test-PublishOutput "Test 3: C# SDK linux-x64 (publish)" (Join-Path $testDir "TestCSharpSdk.Linux.x64") "linux-x64" @("libavcodec.so.62.11.100","libavdevice.so.62.1.100","libavfilter.so.11.4.100","libavformat.so.62.3.100","libavutil.so.60.8.100","libswresample.so.6.1.100","libswscale.so.9.1.100","ffmpeg","ffplay","ffprobe")
if (-not $r3) { $allPassed = $false; $results += "FAIL: C# SDK linux-x64" } else { $results += "PASS: C# SDK linux-x64" }

$r4 = Test-PublishOutput "Test 4: C# SDK linux-arm64 (publish)" (Join-Path $testDir "TestCSharpSdk.Linux.arm64") "linux-arm64" @("libavcodec.so.62.11.100","libavdevice.so.62.1.100","libavfilter.so.11.4.100","libavformat.so.62.3.100","libavutil.so.60.8.100","libswresample.so.6.1.100","libswscale.so.9.1.100","ffmpeg","ffplay","ffprobe")
if (-not $r4) { $allPassed = $false; $results += "FAIL: C# SDK linux-arm64" } else { $results += "PASS: C# SDK linux-arm64" }

# ============================================
# C# .NET Framework Test
# ============================================
Write-Host "=== Test 5: C# .NET Framework 4.7.2 (build + run) ===" -ForegroundColor Yellow
$fwDir = Join-Path $testDir "TestCSharpFramework"

if (-not $msbuild) {
    Write-Host "  SKIP: MSBuild not found" -ForegroundColor DarkYellow
    $results += "SKIP: C# .NET Framework"
} else {
    Remove-Item -Recurse -Force (Join-Path $fwDir "bin"), (Join-Path $fwDir "obj") -ErrorAction SilentlyContinue
    Write-Host "  Building (MSBuild + restore)..."
    $buildOutput = & $msbuild.FullName "$fwDir\TestCSharpFramework.csproj" /t:Build /p:Configuration=Debug /p:Platform=x64 /restore /p:RestoreNoCache=true /v:minimal 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAIL: build" -ForegroundColor Red
        $buildOutput | ForEach-Object { Write-Host "    $_" }
        $allPassed = $false; $results += "FAIL: C# .NET Framework"
    } else {
        Write-Host "  Running..."
        $output = & "$fwDir\bin\Debug\TestCSharpFramework.exe" 2>&1
        $missing = $output | Select-String "MISSING!"
        if ($missing) {
            Write-Host "  FAIL: missing native files" -ForegroundColor Red
            $output | ForEach-Object { Write-Host "    $_" }
            $allPassed = $false; $results += "FAIL: C# .NET Framework"
        } else {
            Write-Host "  PASS" -ForegroundColor Green
            $results += "PASS: C# .NET Framework"
        }
    }
}
Write-Host ""

# ============================================
# C++ Tests
# ============================================
$rc = Test-CppVcxproj "Test 6: C++ vcxproj win-x64 (build)" (Join-Path $testDir "TestCpp.Win.x64") "x64" $true
if ($rc -eq "FAIL") { $allPassed = $false }
$results += "C++ win-x64 : $rc"
Write-Host ""

$rc = Test-CppVcxproj "Test 7: C++ vcxproj win-x86 (build)" (Join-Path $testDir "TestCpp.Win.x86") "Win32" $true
if ($rc -eq "FAIL") { $allPassed = $false }
$results += "C++ win-x86 : $rc"
Write-Host ""

$rc = Test-CppVcxproj "Test 8: C++ vcxproj win-arm64 (build)" (Join-Path $testDir "TestCpp.Win.arm64") "ARM64" $true
if ($rc -eq "FAIL") { $allPassed = $false }
$results += "C++ win-arm64 : $rc"
Write-Host ""

$rc = Test-CppVcxproj "Test 9: C++ vcxproj linux-x64 (restore)" (Join-Path $testDir "TestCpp.Linux.x64") "x64" $false
if ($rc -eq "FAIL") { $allPassed = $false }
$results += "C++ linux-x64 : $rc"
Write-Host ""

$rc = Test-CppVcxproj "Test 10: C++ vcxproj linux-arm64 (restore)" (Join-Path $testDir "TestCpp.Linux.arm64") "ARM64" $false
if ($rc -eq "FAIL") { $allPassed = $false }
$results += "C++ linux-arm64 : $rc"
Write-Host ""


# ============================================
# Summary
# ============================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " RESULTS" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
foreach ($r in $results) {
    if ($r -match "PASS") { Write-Host "  $r" -ForegroundColor Green }
    elseif ($r -match "FAIL") { Write-Host "  $r" -ForegroundColor Red }
    else { Write-Host "  $r" -ForegroundColor DarkYellow }
}
Write-Host ""
if ($allPassed) {
    Write-Host " ALL TESTS PASSED" -ForegroundColor Green
} else {
    Write-Host " SOME TESTS FAILED" -ForegroundColor Red
}
Write-Host "========================================" -ForegroundColor Cyan

