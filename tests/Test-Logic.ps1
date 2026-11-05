#requires -Version 5.1
# Parse the real script and load only pure helper functions.
# No COM activation, device enumeration, configuration writes or audio changes.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'AudioSwitcher.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptFile, [ref]$tokens, [ref]$parseErrors)

if ($parseErrors.Count -ne 0) { throw (($parseErrors | ForEach-Object Message) -join "`n") }

$functions = @('Get-OptionalProperty', 'Find-DeviceNumber', 'Select-TargetProfile', 'New-DeviceSetting', 'Assert-Configuration', 'Resolve-TargetProfile')

foreach ($name in $functions) {
    $node = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)

    if ($null -eq $node) { throw "Function $name was not found." }

    . ([scriptblock]::Create($node.Extent.Text))
}

$count = 0

function Assert-Equal {
    param($Actual, $Expected, [string]$Name)

    if ($Actual -ne $Expected) { throw "FAIL $Name : received '$Actual'; expected '$Expected'." }

    $script:count++
}

function Assert-Rejected {
    param([scriptblock]$Action, [string]$Name)
    $rejected = $false

    try { & $Action | Out-Null }
    catch { $rejected = $true }

    Assert-Equal $rejected $true $Name
}

function Copy-Settings {
    param($Settings)
    return ($Settings | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
}

Assert-Equal (Select-TargetProfile 'game' 'game') 'B' 'A selects B'
Assert-Equal (Select-TargetProfile 'speakers' 'game') 'A' 'B selects A'
Assert-Equal (Select-TargetProfile 'hdmi' 'game') 'A' 'A third output selects A'
Assert-Equal (Select-TargetProfile $null 'game') 'A' 'No default selects A'
Assert-Equal (Select-TargetProfile '' 'game') 'A' 'An empty default selects A'
Assert-Equal (Select-TargetProfile 'GAME' 'game') 'B' 'Endpoint IDs compare without case sensitivity'

# These IDs are fictitious. Localized device names are deliberately preserved.
$devices = @(
    [pscustomobject]@{ Id = 'game'; Name = 'A50 X Game' },
    [pscustomobject]@{ Id = 'voice'; Name = 'A50 X Voice' },
    [pscustomobject]@{ Id = 'speakers'; Name = 'Altavoces' }
)
Assert-Equal (Find-DeviceNumber $devices 'voice' 1) 2 'Suggestions use endpoint IDs'
Assert-Equal (Find-DeviceNumber $devices 'absent' 3) 3 'An unavailable ID keeps the fallback suggestion'
Assert-Equal (Find-DeviceNumber $devices 'VOICE' 1) 2 'Suggestions accept case differences in IDs'
Assert-Equal (Get-OptionalProperty $null 'Mode' 'fallback') 'fallback' 'A missing object uses the fallback'
Assert-Equal (Get-OptionalProperty ([pscustomobject]@{}) 'Mode' 'fallback') 'fallback' 'A missing property uses the fallback'
Assert-Equal (Get-OptionalProperty ([pscustomobject]@{ Mode = 'Keep' }) 'Mode' 'fallback') 'Keep' 'An existing property is preserved'
Assert-Equal (New-DeviceSetting $devices[2]).Name 'Altavoces' 'Device names retain the Windows language'
$settings = [pscustomobject]@{
    Version = 2
    OutputA = New-DeviceSetting $devices[0]
    OutputB = New-DeviceSetting $devices[2]
    CommunicationsA = [pscustomobject]@{ Mode = 'Device'; Id = 'voice'; Name = 'A50 X Voice' }
    CommunicationsB = [pscustomobject]@{ Mode = 'Device'; Id = 'speakers'; Name = 'Altavoces' }
}
Assert-Configuration $settings
$count++
$roundtrip = Copy-Settings $settings
Assert-Configuration $roundtrip
$count++
Assert-Equal $roundtrip.Version 2 'The persisted schema remains version 2'
Assert-Equal $roundtrip.CommunicationsA.Id 'voice' 'Game and Voice remain separate'
Assert-Equal $roundtrip.CommunicationsB.Id 'speakers' 'Speakers can handle both playback and communications'

$profileA = Resolve-TargetProfile -Settings $roundtrip -Devices $devices -Profile 'A'
Assert-Equal $profileA.OutputId 'game' 'Profile A uses Game for general output'
Assert-Equal $profileA.CommunicationsId 'voice' 'Profile A uses Voice for communications'
Assert-Equal $profileA.CommunicationsName 'A50 X Voice' 'Profile A presents the current device name'
$profileB = Resolve-TargetProfile -Settings $roundtrip -Devices $devices -Profile 'B'
Assert-Equal $profileB.OutputId 'speakers' 'Profile B uses speakers for general output'
Assert-Equal $profileB.CommunicationsId 'speakers' 'Profile B uses speakers for communications'
Assert-Equal $profileB.OutputName 'Altavoces' 'Profile B retains the localized device name'

# Legacy configuration display labels are not schema keys and must not force a migration.
$roundtrip.CommunicationsB = [pscustomobject]@{ Mode = 'Keep'; Id = ''; Name = 'Sin cambios' }
Assert-Configuration $roundtrip
$count++
$keep = Resolve-TargetProfile -Settings $roundtrip -Devices $devices -Profile 'B'
Assert-Equal ($null -eq $keep.CommunicationsId) $true 'Keep passes a real null to the calling logic'
Assert-Equal $keep.CommunicationsName 'Keep unchanged' 'Keep is presented in English without rewriting the configuration'
Assert-Equal $roundtrip.CommunicationsB.Name 'Sin cambios' 'Resolving a profile leaves existing preferences intact'

$renamed = Copy-Settings $settings
$renamed.OutputA.Name = 'An old display name'
$renamed.CommunicationsA.Name = 'Another old display name'
$resolved = Resolve-TargetProfile -Settings $renamed -Devices $devices -Profile 'A'
Assert-Equal $resolved.OutputId 'game' 'Changing a display name does not affect endpoint selection'
Assert-Equal $resolved.OutputName 'A50 X Game' 'Presentation uses the live device name'

Assert-Rejected { Resolve-TargetProfile -Settings $settings -Devices @($devices[1], $devices[2]) -Profile 'A' } 'Missing general output is rejected before switching'
Assert-Rejected { Resolve-TargetProfile -Settings $settings -Devices @($devices[0], $devices[2]) -Profile 'A' } 'Missing communications output is rejected before switching'
Assert-Rejected { Resolve-TargetProfile -Settings $settings -Devices @() -Profile 'A' } 'An empty device list is rejected'
$keepOnly = Resolve-TargetProfile -Settings $roundtrip -Devices @($devices[2]) -Profile 'B'
Assert-Equal $keepOnly.OutputId 'speakers' 'Keep does not require a communications endpoint'

# Only the target profile needs to be available; an unplugged inactive profile is allowed.
$availableB = Resolve-TargetProfile -Settings $settings -Devices @($devices[2]) -Profile 'B'
Assert-Equal $availableB.CommunicationsId 'speakers' 'An unavailable inactive profile does not block the target'
$duplicate = @($devices[0], $devices[0], $devices[1], $devices[2])
Assert-Rejected { Resolve-TargetProfile -Settings $settings -Devices $duplicate -Profile 'A' } 'Ambiguous duplicate endpoint IDs are rejected'

$invalid = Copy-Settings $settings
$invalid.CommunicationsA.Id = ''
Assert-Rejected { Assert-Configuration $invalid } 'Device mode requires an ID'
$invalid = Copy-Settings $settings
$invalid.CommunicationsA.Mode = 'Unknown'
Assert-Rejected { Assert-Configuration $invalid } 'Unknown communications mode is rejected'
$invalid = Copy-Settings $settings
$invalid.OutputA.Id = ' '
Assert-Rejected { Assert-Configuration $invalid } 'General output requires a nonblank ID'
$invalid = Copy-Settings $settings
$invalid.OutputA.Id = 7
Assert-Rejected { Assert-Configuration $invalid } 'Endpoint IDs must be strings'
$invalid = Copy-Settings $settings
$invalid.OutputB.Id = 'GAME'
Assert-Rejected { Assert-Configuration $invalid } 'The two general outputs must differ'
$invalid = Copy-Settings $settings
$invalid.PSObject.Properties.Remove('CommunicationsB')
Assert-Rejected { Assert-Configuration $invalid } 'A missing communications choice is rejected'
$invalid = Copy-Settings $settings
$invalid.Version = 1
Assert-Rejected { Assert-Configuration $invalid } 'Older schemas require explicit setup'
Assert-Rejected { Assert-Configuration $null } 'A missing configuration is rejected'
Write-Host "OK: $count syntax and logic checks. Windows audio was not accessed."
