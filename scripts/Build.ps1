#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    & dotnet restore Deskflip.slnx
    if ($LASTEXITCODE -ne 0) { throw 'Restore failed.' }
    & dotnet build Deskflip.slnx -c Release --no-restore
    if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }
    & dotnet test Deskflip.slnx -c Release --no-build
    if ($LASTEXITCODE -ne 0) { throw 'Tests failed.' }
}
finally {
    Pop-Location
}
