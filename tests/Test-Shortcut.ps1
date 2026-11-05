#requires -Version 5.1
# Exercise real Windows shortcut handling inside a disposable desktop directory.
# The actual desktop and audio settings are never accessed.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Run this test on Windows.'
}

$root = Split-Path $PSScriptRoot -Parent
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'AudioSwitcher.ps1'), [ref]$tokens, [ref]$parseErrors)

if ($parseErrors.Count -ne 0) { throw (($parseErrors | ForEach-Object Message) -join "`n") }

$functionNames = @('Test-OwnedAudioShortcut', 'New-AudioShortcut')
$functionText = @()

foreach ($name in $functionNames) {
    $node = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $false)

    if ($null -eq $node) { throw "Function $name was not found." }

    $functionText += $node.Extent.Text
}

$harness = $functionText -join "`r`n`r`n"
$desktopLookup = "[Environment]::GetFolderPath('DesktopDirectory')"

if ([regex]::Matches($harness, [regex]::Escape($desktopLookup)).Count -ne 1) {
    throw 'The desktop lookup changed; review this test harness before updating it.'
}

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('Audio Switcher shortcut tests ' + [Guid]::NewGuid().ToString('N'))
$desktop = Join-Path $temporary 'Test Desktop'
$executable = Join-Path $temporary 'AudioSwitcher.exe'
$legacyExecutable = Join-Path $temporary 'AlternarAudio.exe'
$linkPath = Join-Path $desktop 'Audio Switcher.lnk'
$legacyPath = Join-Path $desktop 'Alternar audio.lnk'
$unrelatedPath = Join-Path $desktop 'Unrelated.lnk'
$unrelatedTarget = Join-Path $env:SystemRoot 'System32\notepad.exe'
$customIcon = (Join-Path $root 'assets\icons\icon_transparent.ico') + ',0'
$oldDefaultIcon = (Join-Path $env:SystemRoot 'System32\mmsys.cpl') + ',0'
$shell = $null
$count = 0

function Assert-Equal {
    param($Actual, $Expected, [string]$Name)

    if ($Actual -ne $Expected) { throw "FAIL $Name : received '$Actual'; expected '$Expected'." }

    $script:count++
}

function New-TestShortcut {
    param([string]$Path, [string]$Target, [string]$Icon = '', [string]$Arguments = '')
    $link = $shell.CreateShortcut($Path)

    try {
        $link.TargetPath = $Target
        $link.Arguments = $Arguments

        if ($Icon) { $link.IconLocation = $Icon }

        $link.Save()
    }
    finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($link) }
}

function Read-TestShortcut {
    param([string]$Path)
    $link = $shell.CreateShortcut($Path)

    try {
        return [pscustomobject]@{
            TargetPath = $link.TargetPath
            Arguments = $link.Arguments
            WorkingDirectory = $link.WorkingDirectory
            IconLocation = $link.IconLocation
        }
    }
    finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($link) }
}

try {
    [void](New-Item -ItemType Directory -Path $desktop -Force)
    $safeDesktopLiteral = "'" + $desktop.Replace("'", "''") + "'"
    $harness = $harness.Replace($desktopLookup, $safeDesktopLiteral)
    $harnessPath = Join-Path $temporary 'ShortcutHarness.ps1'
    Set-Content -LiteralPath $harnessPath -Value $harness -Encoding UTF8
    . $harnessPath
    $shell = New-Object -ComObject WScript.Shell
    # Dummy targets are never launched; real compiled executables are unnecessary.
    Set-Content -LiteralPath $executable -Value 'Test fixture only.'
    Set-Content -LiteralPath $legacyExecutable -Value 'Test fixture only.'
    New-TestShortcut -Path $unrelatedPath -Target $unrelatedTarget
    $unrelatedHash = (Get-FileHash -LiteralPath $unrelatedPath -Algorithm SHA256).Hash

    $created = New-AudioShortcut -Executable $executable
    $info = Read-TestShortcut $created
    Assert-Equal $created $linkPath 'Create the English shortcut on the test desktop'
    Assert-Equal $info.TargetPath $executable 'Point directly at the GUI executable'
    Assert-Equal $info.Arguments '' 'Do not run a console wrapper'
    Assert-Equal $info.WorkingDirectory $temporary 'Use the installation directory'
    Assert-Equal $info.IconLocation ($executable + ',0') 'Use the embedded icon by default'

    New-TestShortcut -Path $linkPath -Target $executable -Icon $customIcon
    [void](New-AudioShortcut -Executable $executable)
    Assert-Equal (Read-TestShortcut $linkPath).IconLocation $customIcon 'Rebuilding preserves a custom shortcut icon'

    # An unrelated collision must not overwrite either shortcut.
    New-TestShortcut -Path $linkPath -Target $unrelatedTarget
    New-TestShortcut -Path $legacyPath -Target $legacyExecutable -Icon $oldDefaultIcon
    $collisionHash = (Get-FileHash -LiteralPath $linkPath -Algorithm SHA256).Hash
    $legacyHash = (Get-FileHash -LiteralPath $legacyPath -Algorithm SHA256).Hash
    $rejected = $false

    try { [void](New-AudioShortcut -Executable $executable) }
    catch { $rejected = $true }

    Assert-Equal $rejected $true 'Reject an unrelated shortcut with the same name'
    Assert-Equal (Get-FileHash -LiteralPath $linkPath -Algorithm SHA256).Hash $collisionHash 'Preserve the unrelated colliding shortcut'
    Assert-Equal (Get-FileHash -LiteralPath $legacyPath -Algorithm SHA256).Hash $legacyHash 'Preserve the legacy shortcut if migration cannot finish'

    Remove-Item -LiteralPath $linkPath
    [void](New-AudioShortcut -Executable $executable)
    $info = Read-TestShortcut $linkPath
    Assert-Equal $info.TargetPath $executable 'Migrate the known v2 shortcut target'
    Assert-Equal $info.IconLocation ($executable + ',0') 'Replace the legacy system icon with the embedded icon'
    Assert-Equal (Test-Path -LiteralPath $legacyPath) $false 'Remove the owned legacy shortcut only after migration'

    Remove-Item -LiteralPath $linkPath
    New-TestShortcut -Path $legacyPath -Target $legacyExecutable -Icon $customIcon
    [void](New-AudioShortcut -Executable $executable)
    Assert-Equal (Read-TestShortcut $linkPath).IconLocation $customIcon 'Preserve a customized legacy icon during migration'

    Remove-Item -LiteralPath $linkPath
    New-TestShortcut -Path $legacyPath -Target $unrelatedTarget
    $foreignLegacyHash = (Get-FileHash -LiteralPath $legacyPath -Algorithm SHA256).Hash
    [void](New-AudioShortcut -Executable $executable)
    Assert-Equal (Get-FileHash -LiteralPath $legacyPath -Algorithm SHA256).Hash $foreignLegacyHash 'Leave an unrelated legacy shortcut untouched'
    Assert-Equal (Read-TestShortcut $linkPath).TargetPath $executable 'Still create the new shortcut when the legacy name is unrelated'

    Remove-Item -LiteralPath $linkPath
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $legacyScript = Join-Path $temporary 'AlternarAudio.ps1'
    New-TestShortcut -Path $legacyPath -Target $powershell -Icon $oldDefaultIcon -Arguments ('-NoProfile -File "' + $legacyScript + '" -Silencioso')
    [void](New-AudioShortcut -Executable $executable)
    $info = Read-TestShortcut $linkPath
    Assert-Equal $info.TargetPath $executable 'Migrate a known legacy PowerShell shortcut'
    Assert-Equal $info.Arguments '' 'Remove the obsolete PowerShell arguments'
    Assert-Equal (Test-Path -LiteralPath $legacyPath) $false 'Complete legacy script-shortcut migration'
    Assert-Equal (Get-FileHash -LiteralPath $unrelatedPath -Algorithm SHA256).Hash $unrelatedHash 'Leave other desktop shortcuts untouched'
    Write-Host "OK: $count shortcut checks. Only a temporary desktop directory was used."
}
finally {
    if ($null -ne $shell) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }

    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
