<#
.SYNOPSIS
    Pushes the packed .nupkg files in Packages\ to nuget.org, one package at a time.

.DESCRIPTION
    A single wildcard push ("nuget push .\Packages\*.nupkg") stops at the FIRST package that
    fails and never attempts the rest, so one timeout silently truncates a large batch. This
    script pushes each file on its own, keeps going past failures, and reports exactly which
    packages are still missing. It also handles the two failure modes seen in practice:

      * nuget.org enforces a push quota per time window and answers 403 (Quota Exceeded) with
        a "retry after: <seconds>" hint. That is not a bad package - the script waits out the
        window and retries the same file.
      * the Native packages are 20-100 MB and can exceed the 300s default upload timeout.

    Native packages are pushed before Tools packages, so a Tools package is never live while
    the Native package it depends on is still missing.

.PARAMETER Yes
    Skip the confirmation prompt (required when running unattended / as a background task).

.EXAMPLE
    .\PushNuget.ps1
    .\PushNuget.ps1 -Yes
    .\PushNuget.ps1 -Yes -Filter '*.Android.*'
#>
[CmdletBinding()]
param(
    [switch]$Yes,
    [string]$PackagesDir = (Join-Path $PSScriptRoot 'Packages'),
    [string]$Filter = '*.nupkg',
    [string]$Source = 'https://api.nuget.org/v3/index.json',
    [int]$TimeoutSeconds = 900,
    [int]$DelaySeconds = 2,
    [int]$MaxQuotaWaits = 5,
    [string]$LogFile
)

$ErrorActionPreference = 'Stop'

$packages = @(Get-ChildItem -Path $PackagesDir -Filter $Filter -File -ErrorAction SilentlyContinue |
    Sort-Object @{ Expression = { if ($_.Name -like '*.Native.*') { 0 } else { 1 } } }, Name)

if ($packages.Count -eq 0) {
    Write-Host "No packages matching '$Filter' in $PackagesDir" -ForegroundColor Yellow
    return
}

# Copy to the local feed first: harmless, and works without an API key. Never let a problem
# here (feed offline, file locked, disk full) stop the nuget.org push that follows.
$localNuget = $env:localNuget
if (![string]::IsNullOrWhiteSpace($localNuget) -and (Test-Path $localNuget)) {
    try {
        Copy-Item -Path (Join-Path $PackagesDir $Filter) -Destination $localNuget -Force -ErrorAction Stop
        Write-Host "Copied packages to $localNuget"
    }
    catch {
        Write-Host "Could not copy to local feed ${localNuget}: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

$nugetKey = $env:nugetKey
if ([string]::IsNullOrEmpty($nugetKey)) {
    Write-Host "Environment variable 'nugetKey' is not set - nothing was pushed." -ForegroundColor Red
    return
}

if (-not $LogFile) {
    $LogFile = Join-Path $PSScriptRoot ("push-nuget-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

$totalMB = [math]::Round((($packages | Measure-Object Length -Sum).Sum) / 1MB, 1)
Write-Host ""
Write-Host "About to push $($packages.Count) package(s), $totalMB MB total" -ForegroundColor Cyan
Write-Host "  Source : $Source"
Write-Host "  Log    : $LogFile"
Write-Host ""

if (-not $Yes) {
    $answer = Read-Host "Type 'push' to confirm"
    if ($answer -ne 'push') {
        Write-Host "Aborted." -ForegroundColor Yellow
        return
    }
}

"# push started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $($packages.Count) package(s) -> $Source" |
    Out-File -FilePath $LogFile -Encoding utf8

$ok = New-Object System.Collections.Generic.List[string]
$failed = New-Object System.Collections.Generic.List[string]
$index = 0

foreach ($package in $packages) {
    $index++
    $sizeMB = [math]::Round($package.Length / 1MB, 2)
    $label = "[$index/$($packages.Count)] $($package.Name) ($sizeMB MB)"
    Write-Host $label -NoNewline

    $quotaWaits = 0
    $pushed = $false

    while (-not $pushed) {
        # stderr is folded into the captured text on purpose (the quota hint arrives there);
        # $? is unreliable for native exes, so success is judged by $LASTEXITCODE only.
        $output = & nuget push $package.FullName -ApiKey $nugetKey -Source $Source -SkipDuplicate -Timeout $TimeoutSeconds 2>&1 | Out-String
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            $pushed = $true
            $ok.Add($package.Name)
            Write-Host "  OK" -ForegroundColor Green
            "OK    $($package.Name)" | Add-Content -Path $LogFile -Encoding utf8
            break
        }

        # 403 Quota Exceeded: wait out the window the server asks for, then retry the same file.
        $quotaMatch = [regex]::Match($output, 'retry after[:\s]+(\d+)', 'IgnoreCase')
        $isQuota = $output -match 'Quota Exceeded' -or $quotaMatch.Success

        if ($isQuota -and $quotaWaits -lt $MaxQuotaWaits) {
            $quotaWaits++
            $waitSeconds = 1500
            if ($quotaMatch.Success) { $waitSeconds = [int]$quotaMatch.Groups[1].Value + 15 }
            Write-Host "  QUOTA - waiting $waitSeconds s (attempt $quotaWaits/$MaxQuotaWaits)" -ForegroundColor Yellow
            "WAIT  $($package.Name) - quota, sleeping $waitSeconds s" | Add-Content -Path $LogFile -Encoding utf8
            Start-Sleep -Seconds $waitSeconds
            continue
        }

        $failed.Add($package.Name)
        Write-Host "  FAIL (exit $exitCode)" -ForegroundColor Red
        "FAIL  $($package.Name) - exit $exitCode" | Add-Content -Path $LogFile -Encoding utf8
        ($output.Trim() -split "`r?`n" | ForEach-Object { "      | $_" }) | Add-Content -Path $LogFile -Encoding utf8
        break
    }

    if ($index -lt $packages.Count) { Start-Sleep -Seconds $DelaySeconds }
}

Write-Host ""
Write-Host "Pushed OK : $($ok.Count)" -ForegroundColor Green
Write-Host "Failed    : $($failed.Count)" -ForegroundColor $(if ($failed.Count -gt 0) { 'Red' } else { 'Green' })
"# finished $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - ok=$($ok.Count) failed=$($failed.Count)" |
    Add-Content -Path $LogFile -Encoding utf8

if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "Still missing:" -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
    Write-Host "Re-run the same command to retry them; -SkipDuplicate makes already-pushed packages a no-op."
    exit 1
}
