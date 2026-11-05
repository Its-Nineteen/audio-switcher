#requires -Version 5.1
<#
.SYNOPSIS
Switch once between two playback profiles and exit.
.DESCRIPTION
Each profile has a general output and an optional separate communications output.
-Configure: visible setup; build a launcher WITHOUT a console and a desktop shortcut.
-Build: rebuild the launcher and update the shortcut without changing configuration.
-List: list active outputs and all three defaults without changing anything.
-Quiet: suppress success messages (does not prevent a console when starting PowerShell).
-FromLauncher: internal use; the launcher displays errors in a dialog and then exits.
Never changes capture devices, microphones, volume, EQ, formats, drivers or names.
#>
[CmdletBinding()]
param(
    [Alias("Configurar")][switch]$Configure,
    [switch]$Build,
    [Alias("Listar")][switch]$List,
    [Alias("Silencioso")][switch]$Quiet,
    [Alias("DesdeLanzador")][switch]$FromLauncher
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$configPath = Join-Path $PSScriptRoot 'audio-config.json'
$mutex = $null
$mutexTaken = $false

function Get-OptionalProperty {
    param([AllowNull()]$Object, [string]$Name, $Fallback = $null)
    if ($null -eq $Object) { return $Fallback }

    $property = $Object.PSObject.Properties[$Name]

    if ($null -eq $property) { return $Fallback }

    return $property.Value
}


function Read-DeviceNumber {
    param([string]$Prompt, [int]$Count, [int]$DefaultNumber, [switch]$AllowKeep)
    $minimum = 1

    if ($AllowKeep) { $minimum = 0 }

    if ($DefaultNumber -lt $minimum -or $DefaultNumber -gt $Count) {
        throw 'Internal error: suggested number is out of range.'
    }

    while ($true) {
        $text = Read-Host ($Prompt + ' [Enter = ' + $DefaultNumber + ']')

        if ($null -eq $text) { throw 'Setup cancelled: console input is unavailable.' }

        $text = $text.Trim()

        if ($text -eq 'q') { throw 'Setup cancelled.' }

        if ($text -eq '') { return $DefaultNumber }

        $number = 0

        if ([int]::TryParse($text, [ref]$number) -and $number -ge $minimum -and $number -le $Count) {
            return $number
        }

        Write-Host "Enter a number between $minimum and $Count, or q to quit."
    }
}


function Find-DeviceNumber {
    param([object[]]$Devices, [AllowNull()][string]$Id, [int]$Fallback)
    for ($i = 0; $i -lt $Devices.Count; $i++) {
        if ($Devices[$i].Id -eq $Id) { return ($i + 1) }
    }

    return $Fallback
}


function Select-TargetProfile {
    param([AllowNull()][AllowEmptyString()][string]$CurrentId, [string]$OutputAId)
    # Use the actual current default: select A for a third output or no default.
    if ($CurrentId -eq $OutputAId) { return 'B' }

    return 'A'
}


function New-DeviceSetting {
    param($Device)
    return [pscustomobject][ordered]@{ Id = [string]$Device.Id; Name = [string]$Device.Name }
}


function Read-CommunicationsSetting {
    param([string]$ProfileLabel, [object[]]$Devices, [int]$DefaultNumber, $Previous)
    if ($null -ne $Previous) {
        if ((Get-OptionalProperty $Previous 'Mode') -eq 'Keep') {
            $DefaultNumber = 0
        }
        elseif ((Get-OptionalProperty $Previous 'Mode') -eq 'Device') {
            $DefaultNumber = Find-DeviceNumber $Devices (Get-OptionalProperty $Previous 'Id') $DefaultNumber
        }
    }

    Write-Host "`nCOMMUNICATIONS when selecting $ProfileLabel"
    Write-Host 'Choose an output from the list above, or 0 for Keep unchanged.'
    $number = Read-DeviceNumber -Prompt 'Communications output number' -Count $Devices.Count -DefaultNumber $DefaultNumber -AllowKeep

    if ($number -eq 0) {
        return [pscustomobject][ordered]@{ Mode = 'Keep'; Id = ''; Name = 'Keep unchanged' }
    }

    $device = $Devices[$number - 1]
    return [pscustomobject][ordered]@{ Mode = 'Device'; Id = [string]$device.Id; Name = [string]$device.Name }
}


function Assert-Configuration {
    param($Settings)
    if ((Get-OptionalProperty $Settings 'Version') -ne 2) {
        throw 'This configuration uses a different version. Run Setup.cmd once to choose communications for each profile.'
    }

    foreach ($profile in @('A', 'B')) {
        $output = Get-OptionalProperty $Settings ('Output' + $profile)
        $id = Get-OptionalProperty $output 'Id'

        if ($id -isnot [string] -or [string]::IsNullOrWhiteSpace($id)) {
            throw 'A general output is missing. Run Setup.cmd again.'
        }

        $comm = Get-OptionalProperty $Settings ('Communications' + $profile)
        $mode = Get-OptionalProperty $comm 'Mode'

        if ($mode -notin @('Device', 'Keep')) {
            throw 'A profile has no valid communications option. Run Setup.cmd.'
        }

        if ($mode -eq 'Device') {
            $commId = Get-OptionalProperty $comm 'Id'

            if ($commId -isnot [string] -or [string]::IsNullOrWhiteSpace($commId)) {
                throw 'The communications output is invalid. Run Setup.cmd.'
            }
        }
    }

    if ($Settings.OutputA.Id -eq $Settings.OutputB.Id) {
        throw 'The two general outputs must be different. Run Setup.cmd.'
    }
}


function Resolve-TargetProfile {
    param($Settings, [object[]]$Devices, [ValidateSet('A', 'B')][string]$Profile)
    $output = Get-OptionalProperty $Settings ('Output' + $Profile)
    $communications = Get-OptionalProperty $Settings ('Communications' + $Profile)
    $target = @($Devices | Where-Object { $_.Id -eq $output.Id })

    if ($target.Count -ne 1) {
        throw 'The target general output is unavailable. Check connections and PC mode. If its ID changed, run Setup.cmd.'
    }

    $commId = $null
    $commName = 'Keep unchanged'

    if ($communications.Mode -eq 'Device') {
        $comm = @($Devices | Where-Object { $_.Id -eq $communications.Id })

        if ($comm.Count -ne 1) {
            throw 'The target communications output is unavailable. No outputs have changed. Check connections or run Setup.cmd.'
        }

        $commId = [string]$communications.Id
        $commName = $comm[0].Name
    }

    return [pscustomobject]@{
        OutputId = [string]$output.Id
        OutputName = $target[0].Name
        CommunicationsId = $commId
        CommunicationsName = $commName
    }
}


function Build-NoConsoleLauncher {
    $source = Join-Path $PSScriptRoot 'Launcher.cs'
    $icon = Join-Path $PSScriptRoot 'assets\icons\icon_round.ico'

    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw 'Launcher.cs is missing. Extract all project files before building.'
    }

    if (-not (Test-Path -LiteralPath $icon -PathType Leaf)) {
        throw 'assets\icons\icon_round.ico is missing. Restore the supplied icon before building.'
    }

    $exePath = Join-Path $PSScriptRoot 'AudioSwitcher.exe'
    $temporary = Join-Path $PSScriptRoot ('build-' + [Guid]::NewGuid().ToString('N') + '.exe')
    $provider = $null

    try {
        # Use the same .NET Framework compiler as Windows PowerShell Add-Type.
        # Compile to disk without loading/locking the executable in this process.
        $provider = New-Object Microsoft.CSharp.CSharpCodeProvider
        $parameters = New-Object System.CodeDom.Compiler.CompilerParameters
        $parameters.GenerateExecutable = $true
        $parameters.GenerateInMemory = $false
        $parameters.OutputAssembly = $temporary
        $parameters.CompilerOptions = '/target:winexe /win32icon:"' + $icon + '"'
        [void]$parameters.ReferencedAssemblies.Add('System.dll')
        [void]$parameters.ReferencedAssemblies.Add('System.Windows.Forms.dll')
        $result = $provider.CompileAssemblyFromFile($parameters, [string[]]@($source))
        $errors = @($result.Errors | Where-Object { -not $_.IsWarning })

        if ($result.NativeCompilerReturnValue -ne 0 -or $errors.Count -gt 0) {
            throw ('Could not build AudioSwitcher.exe. The existing launcher has been kept. Check Launcher.cs and icon_round.ico. ' + ($errors -join [Environment]::NewLine))
        }

        if (-not (Test-Path -LiteralPath $temporary -PathType Leaf)) {
            throw 'The compiler did not generate the launcher. The existing launcher has been kept.'
        }

        # Replace only after a successful compilation, on the same filesystem.
        if (Test-Path -LiteralPath $exePath -PathType Leaf) {
            [System.IO.File]::Replace($temporary, $exePath, [System.Management.Automation.Language.NullString]::Value)
        }
        else {
            [System.IO.File]::Move($temporary, $exePath)
        }

        return $exePath
    }
    finally {
        if ($null -ne $provider) { $provider.Dispose() }

        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}


function Test-OwnedAudioShortcut {
    param($Shortcut, [string]$Executable)
    $oldExecutable = Join-Path $PSScriptRoot 'AlternarAudio.exe'

    if ($Shortcut.TargetPath -eq $Executable -or $Shortcut.TargetPath -eq $oldExecutable) {
        return $true
    }

    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $oldScript = Join-Path $PSScriptRoot 'AlternarAudio.ps1'
    $newScript = Join-Path $PSScriptRoot 'AudioSwitcher.ps1'
    $arguments = [string]$Shortcut.Arguments

    if ($Shortcut.TargetPath -eq $powershell) {
        # Recognize a direct -File invocation, never a path mentioned by another command.
        $invocation = [regex]::Match($arguments,
            '(?i)^\s*(?:(?:-(?:NoLogo|NoProfile|NonInteractive|STA|MTA)|-(?:ExecutionPolicy|WindowStyle)\s+[a-z0-9]+)\s+)*-File\s+"([^"]+)"(?:\s|$)')

        return ($invocation.Success -and
            ($invocation.Groups[1].Value -eq $oldScript -or $invocation.Groups[1].Value -eq $newScript))
    }

    return $false
}


function New-AudioShortcut {
    param([string]$Executable)
    $shell = $null
    $shortcut = $null
    $legacy = $null

    try {
        $desktop = [Environment]::GetFolderPath('DesktopDirectory')

        if (-not (Test-Path -LiteralPath $desktop -PathType Container)) {
            throw 'The user desktop folder could not be found.'
        }

        $linkPath = Join-Path $desktop 'Audio Switcher.lnk'
        $legacyPath = Join-Path $desktop 'Alternar audio.lnk'
        $shell = New-Object -ComObject WScript.Shell
        $ownsLegacy = $false

        if (Test-Path -LiteralPath $legacyPath -PathType Leaf) {
            $legacy = $shell.CreateShortcut($legacyPath)
            $ownsLegacy = Test-OwnedAudioShortcut $legacy $Executable
        }

        if (Test-Path -LiteralPath $linkPath -PathType Leaf) {
            $shortcut = $shell.CreateShortcut($linkPath)

            if (-not (Test-OwnedAudioShortcut $shortcut $Executable)) {
                throw 'An unrelated Audio Switcher.lnk already exists on the desktop. Rename it yourself before running setup or build again.'
            }
        }
        else {
            if ($ownsLegacy) { Copy-Item -LiteralPath $legacyPath -Destination $linkPath }

            $shortcut = $shell.CreateShortcut($linkPath)
        }

        $previousIcon = [string]$shortcut.IconLocation
        $oldDefaultIcon = (Join-Path $env:SystemRoot 'System32\mmsys.cpl') + ',0'
        $oldExecutable = Join-Path $PSScriptRoot 'AlternarAudio.exe'
        $useDefault = [string]::IsNullOrWhiteSpace($previousIcon) -or $previousIcon -eq ',0' -or
            $previousIcon -eq $oldDefaultIcon -or $previousIcon -eq ($oldExecutable + ',0')
        # Point directly at the GUI executable, never PowerShell or a CMD wrapper.
        $shortcut.TargetPath = $Executable
        $shortcut.Arguments = ''
        $shortcut.WorkingDirectory = $PSScriptRoot
        $shortcut.Description = 'Switch general and communications playback between two profiles'

        if ($useDefault) { $shortcut.IconLocation = $Executable + ',0' }

        $shortcut.Save()

        if ($ownsLegacy) { Remove-Item -LiteralPath $legacyPath }

        return $linkPath
    }
    finally {
        if ($null -ne $legacy) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($legacy) }

        if ($null -ne $shortcut) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut) }

        if ($null -ne $shell) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }
}



try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'This script requires the Windows audio interfaces.'
    }

    if ($FromLauncher) {
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    }

    if ($Configure -and ($Quiet -or $FromLauncher)) {
        throw 'Setup requires a visible console: open Setup.cmd.'
    }

    if (([int]$Configure.IsPresent + [int]$Build.IsPresent + [int]$List.IsPresent) -gt 1) {
        throw 'Use only one of Configure, Build or List.'
    }

    # Keep the mutex shared with earlier local builds; ignore overlapping invocations, no background observer.
    $mutex = [System.Threading.Mutex]::new($false, 'Local\AlternarAudio_OneShot_20261031')

    try { $mutexTaken = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $mutexTaken = $true }

    if (-not $mutexTaken) { exit 0 }

    if ($Build) {
        if ($PSVersionTable.PSEdition -ne 'Desktop') {
            throw 'Use Windows PowerShell 5.1 to build the launcher.'
        }

        $exe = Build-NoConsoleLauncher
        $link = New-AudioShortcut -Executable $exe
        Write-Host "Launcher built: $exe"
        Write-Host "Shortcut updated: $link"
        Write-Host 'Configuration and audio defaults have not changed.'
        exit 0
    }

    if (-not ('AudioSwitcher.Audio' -as [type])) {
        Add-Type -LiteralPath (Join-Path $PSScriptRoot 'CoreAudio.cs')
    }

    $devices = @([AudioSwitcher.Audio]::GetOutputs() | Sort-Object Name, Id)

    if ($devices.Count -eq 0) { throw 'Windows reports no active audio outputs.' }

    if ($List) {
        $consoleId = [AudioSwitcher.Audio]::GetDefaultId(0)
        $multimediaId = [AudioSwitcher.Audio]::GetDefaultId(1)
        $communicationsId = [AudioSwitcher.Audio]::GetDefaultId(2)
        $devices | Select-Object Name, Id,
            @{Name='General'; Expression={ $_.Id -eq $consoleId }},
            @{Name='Multimedia'; Expression={ $_.Id -eq $multimediaId }},
            @{Name='Communications'; Expression={ $_.Id -eq $communicationsId }} | Format-List
        exit 0
    }

    if ($Configure) {
        if ($PSVersionTable.PSEdition -ne 'Desktop') {
            throw 'Use Windows PowerShell 5.1 to build the launcher. Setup.cmd selects it automatically.'
        }

        if ($devices.Count -lt 2) { throw 'Connect and enable both outputs before running setup.' }

        $previous = $null

        if (Test-Path -LiteralPath $configPath -PathType Leaf) {
            try { $previous = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json }
            catch { Write-Host 'The previous configuration cannot be read; a new one will be created.' }
        }

        Write-Host "`nAUDIO SWITCHER - AVAILABLE OUTPUTS`n"

        for ($i = 0; $i -lt $devices.Count; $i++) {
            Write-Host ('[{0}] {1}' -f ($i + 1), $devices[$i].Name)
            Write-Host ('    ID: {0}' -f $devices[$i].Id)
        }

        Write-Host "`nSuggested profiles: A = A50 X Game; B = your speakers. Choose any two outputs. q cancels setup."
        $aDefault = 1
        $game = @($devices | Where-Object { $_.Name -match '(?i)A50\s*X\s+Game' })

        if ($game.Count -eq 1) { $aDefault = Find-DeviceNumber $devices $game[0].Id 1 }

        $previousA = Get-OptionalProperty $previous 'OutputA'
        $aDefault = Find-DeviceNumber $devices (Get-OptionalProperty $previousA 'Id') $aDefault
        $a = (Read-DeviceNumber -Prompt 'General output A (for example, headphones)' -Count $devices.Count -DefaultNumber $aDefault) - 1

        $bDefault = 1

        if ($a -eq 0) { $bDefault = 2 }

        $speakers = @($devices | Where-Object { $_.Id -ne $devices[$a].Id -and $_.Name -match '(?i)Altavoces|Speakers' })

        if ($speakers.Count -eq 1) { $bDefault = Find-DeviceNumber $devices $speakers[0].Id $bDefault }

        $previousB = Get-OptionalProperty $previous 'OutputB'
        $bDefault = Find-DeviceNumber $devices (Get-OptionalProperty $previousB 'Id') $bDefault

        if (($bDefault - 1) -eq $a) {
            $bDefault = 1

            if ($a -eq 0) { $bDefault = 2 }
        }

        do {
            $b = (Read-DeviceNumber -Prompt 'General output B (for example, speakers)' -Count $devices.Count -DefaultNumber $bDefault) - 1

            if ($a -eq $b) { Write-Host 'A and B must be different.' }
        } while ($a -eq $b)

        # Suggest Voice for the headset profile, ONLY when unambiguous.
        $voiceDefault = $a + 1
        $voice = @($devices | Where-Object { $_.Name -match '(?i)A50\s*X\s+Voice' })

        if ($devices[$a].Name -match '(?i)A50\s*X\s+Game' -and $voice.Count -eq 1) {
            $voiceDefault = Find-DeviceNumber $devices $voice[0].Id $voiceDefault
        }

        Write-Host "`nThe communications output is configured separately for EACH profile."
        Write-Host 'The microphone is NEVER changed.'
        $commA = Read-CommunicationsSetting -ProfileLabel 'A' -Devices $devices `
            -DefaultNumber $voiceDefault -Previous (Get-OptionalProperty $previous 'CommunicationsA')
        $commB = Read-CommunicationsSetting -ProfileLabel 'B' -Devices $devices `
            -DefaultNumber ($b + 1) -Previous (Get-OptionalProperty $previous 'CommunicationsB')
        $settings = [pscustomobject][ordered]@{
            Version = 2
            OutputA = New-DeviceSetting $devices[$a]
            OutputB = New-DeviceSetting $devices[$b]
            CommunicationsA = $commA
            CommunicationsB = $commB
        }

        Assert-Configuration $settings
        Write-Host "`nSELECTED PROFILES"
        Write-Host ('A: general = {0}; communications = {1}' -f $settings.OutputA.Name, $commA.Name)
        Write-Host ('B: general = {0}; communications = {1}' -f $settings.OutputB.Name, $commB.Name)
        Write-Host "`nBuilding the launcher without a console..."
        $exe = Build-NoConsoleLauncher

        if (Test-Path -LiteralPath $configPath -PathType Leaf) {
            $backup = $configPath + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
            Copy-Item -LiteralPath $configPath -Destination $backup
        }

        $settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding UTF8
        $link = New-AudioShortcut -Executable $exe
        Write-Host "`nConfiguration saved. The current output has not changed."
        Write-Host "Shortcut updated: $link"
        Write-Host 'Daily use: this shortcut or AudioSwitcher.exe. Neither opens a console.'
        Write-Host 'TestSwitch.cmd and ListDevices.cmd are VISIBLE diagnostic tools.'
        Write-Host 'If you pinned the old shortcut, unpin it and pin the new one.'
        exit 0
    }

    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw 'Run Setup.cmd first and select the outputs for each profile.'
    }

    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Configuration $config
    $current = [AudioSwitcher.Audio]::GetDefaultId(0)
    $profile = Select-TargetProfile -CurrentId $current -OutputAId $config.OutputA.Id
    $target = Resolve-TargetProfile -Settings $config -Devices $devices -Profile $profile
    $commId = $target.CommunicationsId

    # $null in a typed PowerShell->C# string argument can become empty; use the
    # original bool method for Keep, which passes a true CLR null internally.
    if ($null -eq $commId) {
        [AudioSwitcher.Audio]::SetPlaybackDefaults([string]$target.OutputId, $false)
    }
    else {
        [AudioSwitcher.Audio]::SetPlaybackProfile([string]$target.OutputId, $commId)
    }

    if (-not ($Quiet -or $FromLauncher)) {
        Write-Host ('Profile: ' + $profile)
        Write-Host ('General output: ' + $target.OutputName)
        Write-Host ('Communications: ' + $target.CommunicationsName)
        Write-Host 'Microphone: unchanged.'
    }
}
catch {
    $exception = $_.Exception
    # Keep the rollback/context message from our helper, not just its deepest cause.
    while ($exception -is [System.Management.Automation.MethodInvocationException] -and $null -ne $exception.InnerException) {
        $exception = $exception.InnerException
    }

    $message = $exception.Message

    if ($Quiet -and -not $FromLauncher) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [void][System.Windows.Forms.MessageBox]::Show($message, 'Audio Switcher - Error', 'OK', 'Error')
        }
        catch { [Console]::Error.WriteLine($message) }
    }
    else { [Console]::Error.WriteLine($message) }
    exit 1
}
finally {
    if ($mutexTaken -and $null -ne $mutex) { $mutex.ReleaseMutex() }

    if ($null -ne $mutex) { $mutex.Dispose() }
}
