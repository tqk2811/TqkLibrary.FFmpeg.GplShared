Remove-Item -Recurse -Force .\Packages\** -ErrorAction SilentlyContinue
dotnet run --project .\AutoPackager\AutoPackager.csproj
