param([Parameter(Mandatory=$true)][ValidateSet('dolphin','cemu')][string]$Emulator,
      [Parameter(Mandatory=$true)][string]$Archive,
      [string]$Report = 'windows-launch.json',
      [string]$ForbiddenRoot = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$archivePath = (Resolve-Path $Archive).Path
$reportPath = [IO.Path]::GetFullPath($Report)
$root = Join-Path ([IO.Path]::GetTempPath()) ('s2k extracted GUI ' + [guid]::NewGuid())
$record = @{ version=1; emulator=$Emulator; archiveSHA256=(Get-FileHash $archivePath -Algorithm SHA256).Hash;
             testedRevision=$env:GITHUB_SHA; physicalControllerTested=$false; pristineFirstRunTested=$false;
             runs=@(); status='failed' }
New-Item -ItemType Directory $root | Out-Null
try {
    $unpack = Join-Path $root 'unpacked'
    Expand-Archive $archivePath $unpack
    $prefixes = @(Get-ChildItem $unpack)
    if ($prefixes.Count -ne 1 -or -not $prefixes[0].PSIsContainer) { throw 'Expected one application directory in the archive.' }
    $directory = $prefixes[0].FullName
    $name = if ($Emulator -eq 'dolphin') { 'Dolphin.exe' } else { 'Cemu_release.exe' }
    $exe = Join-Path $directory $name
    $expected = (Resolve-Path (Join-Path $directory 'Switch2KitC.dll')).Path
    foreach ($notice in @('CREDITS.md','LICENSES/MIT-trevlars.txt','LICENSES/SDL-zlib.txt','SwiftRuntime/LICENSE.txt','SwiftRuntime/ICU.txt')) {
        if (-not (Test-Path (Join-Path $directory "Switch2KitNotices/$notice"))) { throw "Missing distributed license/attribution: $notice" }
    }
    $home = Join-Path $root 'home'
    $temp = Join-Path $root 'tmp'
    New-Item -ItemType Directory $home, $temp, "$home/AppData/Roaming", "$home/AppData/Local" | Out-Null
    if ($Emulator -eq 'dolphin') {
        $user = Join-Path $root 'user'
        New-Item -ItemType Directory "$user/Config" | Out-Null
        [IO.File]::WriteAllText("$user/Config/Dolphin.ini", "[Analytics]`nEnabled=False`nPermissionAsked=True`n[AutoUpdate]`nUpdateTrack=`n")
        if (-not (Test-Path "$directory/Sys/Profiles/GCPad/Switch2Kit GameCube.ini")) { throw 'Missing GameCube mapping resource.' }
    } else {
        # This documented compatibility path is honored even when optional
        # CEMU_ALLOW_PORTABLE is disabled. Never touch the real Windows profile.
        $settings = Join-Path $directory 'settings.xml'
        if (Test-Path $settings) { throw 'The application archive unexpectedly contains user settings.' }
        [IO.File]::WriteAllText($settings, '<?xml version="1.0"?><content><check_update>false</check_update><use_discord_presence>false</use_discord_presence></content>')
        if (-not (Test-Path "$directory/resources")) { throw 'Missing Cemu resources.' }
    }
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $start = [Diagnostics.ProcessStartInfo]::new($exe)
        $start.UseShellExecute = $false
        $start.WorkingDirectory = $directory
        $start.Environment.Clear()
        $values = @{ PATH="$env:SystemRoot\System32;$env:SystemRoot"; SystemRoot=$env:SystemRoot;
                     WINDIR=$env:SystemRoot; SystemDrive=$env:SystemDrive; USERPROFILE=$home;
                     APPDATA="$home/AppData/Roaming"; LOCALAPPDATA="$home/AppData/Local"; TEMP=$temp; TMP=$temp }
        foreach ($entry in $values.GetEnumerator()) { $start.Environment[$entry.Key] = $entry.Value }
        if ($Emulator -eq 'dolphin') { $start.ArgumentList.Add('--user'); $start.ArgumentList.Add($user) }
        $process = [Diagnostics.Process]::Start($start)
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(60)
            do {
                Start-Sleep -Milliseconds 250
                $process.Refresh()
                if ($process.HasExited) { throw "Application exited before opening a GUI: $($process.ExitCode)" }
            } until ($process.MainWindowHandle -ne 0 -or [DateTime]::UtcNow -gt $deadline)
            if ($process.MainWindowHandle -eq 0) { throw 'No application window appeared within 60 seconds.' }
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            do {
                Start-Sleep -Milliseconds 250
                $process.Refresh()
                if ($process.HasExited -or $process.MainWindowHandle -eq 0) { throw 'The application did not retain a usable GUI.' }
            } until ([DateTime]::UtcNow -ge $deadline)
            $modules = @($process.Modules)
            $loaded = @($modules | Where-Object { $_.ModuleName -eq 'Switch2KitC.dll' })
            if ($loaded.Count -ne 1 -or $loaded[0].FileName -ne $expected) { throw 'The GUI did not load its packaged controller DLL.' }
            $runtime = @($modules | Where-Object { $_.ModuleName -match '^(swift|Foundation|_Foundation|dispatch|BlocksRuntime)' })
            if (-not ($runtime | Where-Object { $_.ModuleName -eq 'swiftCore.dll' })) { throw 'The running GUI did not load the Swift runtime.' }
            foreach ($module in $runtime) {
                if (-not $module.FileName.StartsWith($directory + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Swift runtime escaped the extracted application: $($module.FileName)"
                }
            }
            if ($ForbiddenRoot) {
                $blocked = [IO.Path]::GetFullPath($ForbiddenRoot).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
                foreach ($module in $modules) {
                    if ($module.FileName.StartsWith($blocked, [StringComparison]::OrdinalIgnoreCase)) { throw "Build dependency loaded: $($module.FileName)" }
                }
            }
            if (-not $process.CloseMainWindow()) { throw 'The application rejected a normal close request.' }
            if (-not $process.WaitForExit(20000)) { throw 'The application did not shut down normally.' }
            if ($process.ExitCode -ne 0) { throw "Application failed during shutdown: $($process.ExitCode)" }
            $record.runs += @{ attempt=$attempt; visibleWindow=$true; stableSeconds=5; localControllerDLL=$true;
                              runtimeLibraries=@($runtime | ForEach-Object { $_.ModuleName }); exitCode=$process.ExitCode }
        } finally {
            if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
            $process.Dispose()
        }
    }
    $record.status = 'passed'
} catch {
    $record.reason = $_.Exception.Message
    throw
} finally {
    $record | ConvertTo-Json -Depth 6 | Set-Content $reportPath
    Remove-Item $root -Recurse -Force
}
Write-Output 'PASS exact extracted archive: GUI window, packaged DLL/runtime, normal quit and relaunch; no physical controller claim'
