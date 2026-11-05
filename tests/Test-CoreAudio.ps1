#requires -Version 5.1
<#
.SYNOPSIS
Tests the production profile-switching methods with an in-memory audio boundary.
.DESCRIPTION
No Windows audio APIs are called. The C# methods are extracted from CoreAudio.cs;
only policy-object creation is redirected. Endpoint enumeration, defaults and
COM release are supplied by the harness. This is not a hardware integration test.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = Get-Content -LiteralPath (Join-Path $root 'CoreAudio.cs') -Raw -Encoding UTF8

function Get-CSharpMethod {
    param([string]$Text, [string]$Signature)
    $start = $Text.IndexOf($Signature, [StringComparison]::Ordinal)

    if ($start -lt 0) { throw "Method not found: $Signature" }

    $body = $Text.IndexOf('{', $start)
    # Ignore braces inside C# strings, character literals and comments.
    $pattern = @'
//[^\r\n]*|/\*[\s\S]*?\*/|@"(?:[^"]|"")*"|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[{}]
'@
    $depth = 0

    foreach ($token in [regex]::Matches($Text.Substring($body), $pattern)) {
        if ($token.Value -eq '{') { $depth++ }
        elseif ($token.Value -eq '}') {
            $depth--

            if ($depth -eq 0) {
                return $Text.Substring($start, $body + $token.Index + 1 - $start)
            }
        }
    }

    throw "Unterminated method: $Signature"
}

$methods = @(
    Get-CSharpMethod $source 'private static void Check(int result)'
    Get-CSharpMethod $source 'public static void SetPlaybackDefaults(string id, bool includeCommunications)'
    Get-CSharpMethod $source 'public static void SetPlaybackProfile(string playbackId, string communicationsId)'
) -join "`n"
$creation = 'Activator.CreateInstance(Type.GetTypeFromCLSID(PolicyClass))'

if ([regex]::Matches($methods, [regex]::Escape($creation)).Count -ne 1) {
    throw 'The policy-creation boundary changed; review this test harness before updating it.'
}

$methods = $methods.Replace($creation, 'CreatePolicy()')
$prefix = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace AudioSwitcherCoreAudioTests
{
    public sealed class OutputDevice
    {
        public string Id { get; set; }
    }

    internal interface IPolicyConfig
    {
        int SetDefaultEndpoint(string id, int role);
    }

    public static class Audio
    {
        public static string[] Defaults;
        public static List<string> Calls;
        public static int[] FailCalls;
        public static int[] ThrowCalls;
        public static int[] IgnoreCalls;
        public static bool FailCreation;
        public static int Created;
        public static int Released;

        public static void Reset()
        {
            Defaults = new[] { "speakers", "speakers", "speakers" };
            Calls = new List<string>();
            FailCalls = new int[0];
            ThrowCalls = new int[0];
            IgnoreCalls = new int[0];
            FailCreation = false;
            Created = 0;
            Released = 0;
        }

        public static OutputDevice[] GetOutputs()
        {
            return new[] {
                new OutputDevice { Id = "game" },
                new OutputDevice { Id = "voice" },
                new OutputDevice { Id = "speakers" }
            };
        }

        public static string GetDefaultId(int role)
        {
            return Defaults[role];
        }

        public static void ClearDefault(int role)
        {
            Defaults[role] = null;
        }

        private static object CreatePolicy()
        {
            if (FailCreation) throw new InvalidOperationException("Injected policy creation failure.");

            Created++;
            return new FakePolicy();
        }

        private static void Release(object instance)
        {
            if (instance != null) Released++;
        }

        private sealed class FakePolicy : IPolicyConfig
        {
            public int SetDefaultEndpoint(string id, int role)
            {
                if (role < 0 || role > 2) throw new ArgumentOutOfRangeException("role");

                Calls.Add(role + "=" + id);
                int number = Calls.Count;

                if (Array.IndexOf(ThrowCalls, number) >= 0)
                    throw new InvalidOperationException("Injected endpoint exception.");

                if (Array.IndexOf(FailCalls, number) >= 0)
                    return unchecked((int)0x80004005);

                if (Array.IndexOf(IgnoreCalls, number) < 0) Defaults[role] = id;

                return 0;
            }
        }
'@
$suffix = @'
    }
}
'@
# A unique namespace permits repeated execution in the same PowerShell process.
$harness = ($prefix + "`n" + $methods + "`n" + $suffix).Replace(
    'AudioSwitcherCoreAudioTests', 'AudioSwitcherCoreAudioTests_' + [Guid]::NewGuid().ToString('N'))
$audio = Add-Type -TypeDefinition $harness -PassThru | Where-Object Name -eq 'Audio'
$count = 0

function Assert-Equal {
    param($Actual, $Expected, [string]$Name)

    if ($Actual -cne $Expected) {
        throw "FAIL $Name : received '$Actual'; expected '$Expected'."
    }

    $script:count++
}

function Assert-Failure {
    param([scriptblock]$Action, [string]$Name)
    $caught = $null

    try { & $Action }
    catch { $caught = $_.Exception.GetBaseException() }

    if ($null -eq $caught) { throw "FAIL $Name : expected an error." }

    $script:count++
    return $caught
}

function Assert-ProfileFailure {
    param([string]$Message, [string]$Name)
    $failure = $null

    try { $audio::SetPlaybackProfile('game', 'voice') }
    catch { $failure = $_.Exception.Message }

    if ($null -eq $failure -or $failure -notlike ('*' + $Message + '*')) {
        throw "FAIL $Name : expected '$Message'; received '$failure'."
    }

    $script:count++
}

$audio::Reset()
$audio::SetPlaybackProfile('game', 'voice')
Assert-Equal ($audio::Defaults -join ',') 'game,game,voice' 'Separate playback and communications'
Assert-Equal ($audio::Calls -join ',') '0=game,1=game,2=voice' 'Playback roles, communications last'
Assert-Equal $audio::Released 1 'Release policy after success'

$audio::Reset()
$audio::Defaults[2] = 'voice'
$audio::SetPlaybackDefaults('game', $false)
Assert-Equal ($audio::Defaults -join ',') 'game,game,voice' 'Keep preserves communications'
Assert-Equal ($audio::Calls -join ',') '0=game,1=game,2=voice' 'Keep reasserts the previous communications endpoint'

$audio::Reset()
$audio::ClearDefault(2)
$audio::SetPlaybackDefaults('game', $false)
Assert-Equal $audio::Defaults[2] $null 'Keep with no communications default'
Assert-Equal $audio::Calls.Count 2 'No request for a missing communications default'

$audio::Reset()
$null = Assert-Failure { $audio::SetPlaybackProfile('missing', 'voice') } 'Missing playback endpoint'
Assert-Equal $audio::Calls.Count 0 'Missing playback causes no partial change'
Assert-Equal $audio::Created 0 'Missing playback rejected before policy creation'

$audio::Reset()
$null = Assert-Failure { $audio::SetPlaybackProfile('game', 'missing') } 'Missing communications endpoint'
Assert-Equal $audio::Calls.Count 0 'Missing communications causes no partial change'
Assert-Equal ($audio::Defaults -join ',') 'speakers,speakers,speakers' 'Preflight preserves all defaults'

$audio::Reset()
$null = Assert-Failure { $audio::SetPlaybackProfile('', 'voice') } 'Empty playback ID'
$null = Assert-Failure { $audio::SetPlaybackProfile('game', '') } 'Empty communications ID'
Assert-Equal $audio::Created 0 'Invalid IDs rejected before policy creation'

$audio::Reset()
$audio::FailCalls = @(2)
Assert-ProfileFailure 'The previous outputs have been restored.' 'Rollback after a failed Multimedia change'
Assert-Equal ($audio::Defaults -join ',') 'speakers,speakers,speakers' 'Restore every previous default'
Assert-Equal ($audio::Calls -join ',') '0=game,1=game,0=speakers,1=speakers,2=speakers' 'Rollback order'
Assert-Equal $audio::Released 1 'Release policy after failure'

$audio::Reset()
$audio::FailCalls = @(3)
Assert-ProfileFailure 'The previous outputs have been restored.' 'Rollback after a failed Communications change'
Assert-Equal ($audio::Defaults -join ',') 'speakers,speakers,speakers' 'Restore after two successful changes'

$audio::Reset()
$audio::IgnoreCalls = @(2)
Assert-ProfileFailure 'Windows did not retain the requested audio profile.' 'Detect a silently ignored change'
Assert-Equal ($audio::Defaults -join ',') 'speakers,speakers,speakers' 'Rollback after verification failure'

$audio::Reset()
$audio::FailCalls = @(3, 4)
Assert-ProfileFailure 'A complete restoration could not be confirmed.' 'Report a failed rollback HRESULT'
Assert-Equal ($audio::Defaults -join ',') 'game,speakers,speakers' 'Incomplete rollback remains visible'
Assert-Equal $audio::Calls.Count 6 'Continue restoring other roles after a rollback failure'
Assert-Equal $audio::Released 1 'Release policy after incomplete rollback'

$audio::Reset()
$audio::ThrowCalls = @(3, 4)
Assert-ProfileFailure 'A complete restoration could not be confirmed.' 'Handle exceptions during change and rollback'
Assert-Equal $audio::Calls.Count 6 'Continue restoring after a rollback exception'
Assert-Equal $audio::Released 1 'Release policy after rollback exception'

$audio::Reset()
$audio::ClearDefault(0)
$audio::FailCalls = @(2)
Assert-ProfileFailure 'A complete restoration could not be confirmed.' 'Cannot restore an absent default'
Assert-Equal $audio::Defaults[0] 'game' 'Never claim an absent default was restored'

$audio::Reset()
$audio::FailCreation = $true
Assert-ProfileFailure 'Injected policy creation failure.' 'Policy activation failure'
Assert-Equal $audio::Calls.Count 0 'No rollback before any change is attempted'
Assert-Equal $audio::Released 0 'No COM object to release after activation failure'

$audio::Reset()
$audio::SetPlaybackDefaults('game', $true)
Assert-Equal ($audio::Defaults -join ',') 'game,game,game' 'Legacy entry point with communications'

$audio::Reset()
$audio::Defaults[2] = 'voice'
$audio::SetPlaybackDefaults('game', $false)
Assert-Equal ($audio::Defaults -join ',') 'game,game,voice' 'Legacy entry point preserves communications'

Write-Host "OK: $count Core Audio assertions. Only in-memory endpoints were used; no system audio was accessed."
