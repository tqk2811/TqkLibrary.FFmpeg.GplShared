Remove-Item -Recurse -Force .\Release\** -ErrorAction SilentlyContinue
nuget pack .\TqkLibrary.FFmpeg.GplShared.nuspec -OutputDirectory .\Release
nuget pack .\TqkLibrary.FFmpeg.Runtimes.nuspec -OutputDirectory .\Release

$localNuget = $env:localNuget
if(![string]::IsNullOrWhiteSpace($localNuget))
{
    Copy-Item .\Release\*.nupkg -Destination $localNuget -Force
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

	nuget push ".\Release\*" -ApiKey $($nugetKey) -Source "https://api.nuget.org/v3/index.json" -SkipDuplicate
}
pause