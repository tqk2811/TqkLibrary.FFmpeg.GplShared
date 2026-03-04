$localNuget = $env:localNuget
if(![string]::IsNullOrWhiteSpace($localNuget) -and (Test-Path $localNuget))
{
    Copy-Item .\Packages\*.nupkg -Destination $localNuget -Force
    Write-Host "Copied packages to $localNuget"
}

$nugetKey=$env:nugetKey
if([string]::IsNullOrEmpty($nugetKey))
{
	Write-Host "Pack success"
	pause
}
else
{
	Write-Host "enter to push nuget"
	pause
	Write-Host "enter to confirm"
    pause

	nuget push ".\Packages\*.nupkg" -ApiKey $($nugetKey) -Source "https://api.nuget.org/v3/index.json" -SkipDuplicate
}
pause