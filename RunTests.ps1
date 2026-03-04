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
Write-Host " NuGet Package Test Runner (Multi-Target)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $packagesDir) -or (Get-ChildItem $packagesDir -Filter '*.nupkg').Count -eq 0) {
    Write-Host "ERROR: No packages found in $packagesDir" -ForegroundColor Red
    Write-Host "Run Build.ps1 first to generate packages." -ForegroundColor Yellow
    exit 1
}

$allPassed = $true
$results = @()

function Test-CSharpPublish {
    param(
        [string]$ProjectDir,
        [string]$Rid,
        [string]$Framework,
        [string[]]$ExpectedFiles
    )

    $Name = "C# publish ($Framework) [$Rid]"
    Write-Host "=== $Name ===" -ForegroundColor Yellow
    $proj = Get-ChildItem $ProjectDir -Filter '*.csproj' | Select-Object -First 1

    Write-Host "  Publishing ($Rid)..."
    $pubDir = Join-Path $ProjectDir "bin\publish\$Rid"
    Remove-Item -Recurse -Force $pubDir -ErrorAction SilentlyContinue
    $pubOut = dotnet publish --no-restore -r $Rid -f $Framework -c Release -o $pubDir $proj.FullName 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAIL: publish" -ForegroundColor Red
        $pubOut | ForEach-Object { Write-Host "    $_" }
        return "FAIL"
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
        if ($Framework -eq "net472" -and $Rid -match "linux") {
            # Linux under net472 is impossible/unsupported in our setup, but if it passes the logic checks, it passes
            Write-Host "  PASS" -ForegroundColor Green
            return "PASS"
        }
        
        Write-Host "  PASS" -ForegroundColor Green
        return "PASS"
    } else {
        Write-Host "  FAIL: some files missing" -ForegroundColor Red
        return "FAIL"
    }
}

function Test-CppVcxproj {
    param(
        [string]$Name,
        [string]$ProjectDir,
        [string]$Platform,
        [string]$AppType,
        [bool]$Build
    )
    
    Write-Host "=== $Name ===" -ForegroundColor Yellow
    
    if (-not $msbuild) {
        Write-Host "  SKIP: MSBuild not found" -ForegroundColor DarkYellow
        return "SKIP"
    }
    
    $proj = Get-ChildItem $ProjectDir -Filter '*.vcxproj' | Select-Object -First 1
    
    $argsBuilder = @("/p:Platform=$Platform", "/p:RestoreNoCache=true", "/v:minimal")
    if ($AppType) {
        $argsBuilder += "/p:ApplicationType=$AppType"
    }

    Write-Host "  Restoring ($Platform)..."
    $restoreArgs = @("/t:Restore") + $argsBuilder
    $restoreOut = & $msbuild.FullName $proj.FullName $restoreArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAIL: restore" -ForegroundColor Red
        $restoreOut | ForEach-Object { Write-Host "    $_" }
        return "FAIL"
    }
    
    if ($Build) {
        Write-Host "  Building ($Platform)..."
        $buildArgs = @("/t:Build", "/p:Configuration=Debug") + $argsBuilder
        $buildOutput = & $msbuild.FullName $proj.FullName $buildArgs 2>&1
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
# Prepare & Clean
# ============================================
$csharpDir = Join-Path $testDir "TestCSharp"
$cppDir = Join-Path $testDir "TestCpp"
Remove-Item -Recurse -Force (Join-Path $csharpDir "bin"), (Join-Path $csharpDir "obj") -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force (Join-Path $cppDir "x64"), (Join-Path $cppDir "Win32"), (Join-Path $cppDir "ARM64"), (Join-Path $cppDir "Debug"), (Join-Path $cppDir "obj") -ErrorAction SilentlyContinue

# Expected Files
$winExpected = @("avcodec-62.dll","avdevice-62.dll","avfilter-11.dll","avformat-62.dll","avutil-60.dll","swresample-6.dll","swscale-9.dll","ffmpeg.exe","ffplay.exe","ffprobe.exe")
$linuxExpected = @("libavcodec.so.62.11.100","libavdevice.so.62.1.100","libavfilter.so.11.4.100","libavformat.so.62.3.100","libavutil.so.60.8.100","libswresample.so.6.1.100","libswscale.so.9.1.100","ffmpeg","ffplay","ffprobe")

# ============================================
# C# multi-target tests
# ============================================
Write-Host "restoring TestCSharp globally for all RIDs..." -ForegroundColor Yellow
$csharpProjFile = Get-ChildItem $csharpDir -Filter '*.csproj' | Select-Object -First 1
$restoreOut = dotnet restore --no-cache $csharpProjFile.FullName 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "FAIL: global restore failed" -ForegroundColor Red
    $restoreOut | ForEach-Object { Write-Host "  $_" }
    exit 1
}

$csharpTests = @(
    @{ Rid="win-x64"; Fw="net8.0"; Files=$winExpected },
    @{ Rid="win-x86"; Fw="net8.0"; Files=$winExpected },
    @{ Rid="win-arm64"; Fw="net8.0"; Files=$winExpected },
    @{ Rid="linux-x64"; Fw="net8.0"; Files=$linuxExpected },
    @{ Rid="linux-arm64"; Fw="net8.0"; Files=$linuxExpected },
    @{ Rid="win-x64"; Fw="net472"; Files=$winExpected }
)

foreach ($t in $csharpTests) {
    if ($t.Fw -eq "net472" -and -not $isWindows) { continue }
    $rc = Test-CSharpPublish $csharpDir $t.Rid $t.Fw $t.Files
    if ($rc -eq "FAIL") { $allPassed = $false }
    $results += "C# SDK ($($t.Fw)) [$($t.Rid)] : $rc"
    Write-Host ""
}

# ============================================
# C++ multi-target tests
# ============================================
$cppTests = @(
    @{ Name="C++ win-x64"; Platform="x64"; AppType=""; Build=$true },
    @{ Name="C++ win-x86"; Platform="Win32"; AppType=""; Build=$true },
    @{ Name="C++ win-arm64"; Platform="ARM64"; AppType=""; Build=$true },
    @{ Name="C++ linux-x64"; Platform="x64"; AppType="Linux"; Build=$false },
    @{ Name="C++ linux-arm64"; Platform="ARM64"; AppType="Linux"; Build=$false }
)

foreach ($t in $cppTests) {
    $rc = Test-CppVcxproj $t.Name $cppDir $t.Platform $t.AppType $t.Build
    if ($rc -eq "FAIL") { $allPassed = $false }
    $results += "$($t.Name) : $rc"
    Write-Host ""
}

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
if (-not $allPassed) { exit 1 }
exit 0
