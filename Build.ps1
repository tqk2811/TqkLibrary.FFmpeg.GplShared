Remove-Item -Recurse -Force .\Release\** -ErrorAction SilentlyContinue
nuget pack .\TqkLibrary.FFmpeg.GplShared.nuspec -OutputDirectory .\Release

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

	$files = [System.IO.Directory]::GetFiles(".\Release\")
	nuget push $($files[0]) -ApiKey $($nugetKey) -Source "https://api.nuget.org/v3/index.json"
}
pause