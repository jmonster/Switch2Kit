param([string]$CBuild = "build-c", [string]$SDLBuild = "build-sdl")
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
& python (Join-Path $PSScriptRoot 'relocate-windows.py') --c-build $CBuild --sdl-build $SDLBuild
if ($LASTEXITCODE -ne 0) { throw "Extracted consumer qualification failed ($LASTEXITCODE)" }
