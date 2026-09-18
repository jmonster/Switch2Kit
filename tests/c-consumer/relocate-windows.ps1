param([Parameter(Mandatory=$true)][string]$CBuild,
      [Parameter(Mandatory=$true)][string]$SDLBuild)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Join-Path ([IO.Path]::GetTempPath()) ('s2k relocated consumers ' + [guid]::NewGuid())
$stage = Join-Path $root 'stage'
$archive = Join-Path $root 'consumers.zip'
$extract = Join-Path $root 'extracted package'
New-Item -ItemType Directory $root, $stage | Out-Null
$oldPath = $env:PATH
try {
    foreach ($entry in @(@('c', $CBuild), @('sdl', $SDLBuild))) {
        $destination = Join-Path $stage $entry[0]
        New-Item -ItemType Directory $destination | Out-Null
        Copy-Item (Join-Path $entry[1] '*.exe'), (Join-Path $entry[1] '*.dll') $destination
        Copy-Item (Join-Path $entry[1] 'Switch2KitNotices') $destination -Recurse
        foreach ($notice in @('LICENSES/MIT-trevlars.txt', 'LICENSES/SDL-zlib.txt', 'SwiftRuntime/LICENSE.txt', 'SwiftRuntime/ICU.txt')) {
            if (-not (Test-Path (Join-Path $destination "Switch2KitNotices/$notice"))) { throw "Missing license: $notice" }
        }
    }
    Compress-Archive -Path "$stage/*" -DestinationPath $archive
    Expand-Archive -Path $archive -DestinationPath $extract
    Remove-Item $stage -Recurse
    # Only OS directories; no compiler installation, source checkout or SDK override.
    $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
    foreach ($relative in @('c/c-consumer.exe', 'sdl/sdl-inprocess.exe', 'sdl/sdl-motion.exe')) {
        $exe = Join-Path $extract $relative
        $process = Start-Process $exe -WorkingDirectory (Split-Path $exe) -PassThru
        if (-not $process.WaitForExit(30000)) { $process.Kill(); throw "Timed out: $relative" }
        if ($process.ExitCode -ne 0) { throw "Relocated consumer failed: $relative ($($process.ExitCode))" }
    }
    Write-Output 'PASS extracted real C/SDL consumers with OS-only PATH and packaged Swift runtime'
} finally {
    $env:PATH = $oldPath
    Remove-Item $root -Recurse -Force
}
