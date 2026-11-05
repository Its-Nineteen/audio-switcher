#requires -Version 5.1
# Build in a disposable directory. Never run the launcher or change Windows audio.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Run this test with Windows PowerShell 5.1 on Windows.'
}

$root = Split-Path $PSScriptRoot -Parent
$scriptFile = Join-Path $root 'AudioSwitcher.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptFile, [ref]$tokens, [ref]$parseErrors)

if ($parseErrors.Count -ne 0) { throw (($parseErrors | ForEach-Object Message) -join "`n") }

$functionNodes = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
$buildNode = @($functionNodes | Where-Object Name -eq 'Build-NoConsoleLauncher')

if ($buildNode.Count -ne 1) { throw 'Build-NoConsoleLauncher was not found.' }

# Load the PE as resource data only; do not execute any code in it.
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;

public static class AudioSwitcherResourceTest
{
    private delegate bool ResourceNameCallback(IntPtr module, IntPtr type, IntPtr name, IntPtr parameter);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr LoadLibraryEx(string file, IntPtr handle, uint flags);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FreeLibrary(IntPtr module);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool EnumResourceNames(IntPtr module, IntPtr type, ResourceNameCallback callback, IntPtr parameter);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr FindResource(IntPtr module, IntPtr name, IntPtr type);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint SizeofResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LockResource(IntPtr resource);

    private static byte[] ReadResource(IntPtr module, IntPtr name, int type)
    {
        IntPtr resource = FindResource(module, name, new IntPtr(type));

        if (resource == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());

        uint size = SizeofResource(module, resource);
        IntPtr data = LockResource(LoadResource(module, resource));

        if (size == 0 || data == IntPtr.Zero) throw new InvalidDataException("Empty icon resource.");

        byte[] result = new byte[size];
        Marshal.Copy(data, result, 0, result.Length);
        return result;
    }

    public static int Verify(string executable, string iconPath)
    {
        byte[] pe = File.ReadAllBytes(executable);
        int header = BitConverter.ToInt32(pe, 0x3c);

        if (BitConverter.ToUInt32(pe, header) != 0x00004550 ||
            BitConverter.ToUInt16(pe, header + 92) != 2)
            throw new InvalidDataException("The launcher must use the Windows GUI PE subsystem.");

        byte[] ico = File.ReadAllBytes(iconPath);
        IntPtr module = LoadLibraryEx(executable, IntPtr.Zero, 2);

        if (module == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());

        try
        {
            byte[] group = null;
            int groups = 0;
            ResourceNameCallback callback = delegate(IntPtr m, IntPtr type, IntPtr name, IntPtr parameter)
            {
                group = ReadResource(m, name, 14);
                groups++;
                return true;
            };

            if (!EnumResourceNames(module, new IntPtr(14), callback, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error());

            if (groups != 1 || group == null) throw new InvalidDataException("Expected one default icon group.");

            int count = BitConverter.ToUInt16(ico, 4);

            if (group.Length != 6 + count * 14) throw new InvalidDataException("Icon frame count changed.");

            for (int i = 0; i < 6; i++)
            {
                if (group[i] != ico[i]) throw new InvalidDataException("Icon directory header changed.");
            }

            for (int frame = 0; frame < count; frame++)
            {
                int sourceEntry = 6 + frame * 16;
                int targetEntry = 6 + frame * 14;

                for (int i = 0; i < 12; i++)
                {
                    if (ico[sourceEntry + i] != group[targetEntry + i])
                        throw new InvalidDataException("Icon frame metadata changed.");
                }

                int length = BitConverter.ToInt32(ico, sourceEntry + 8);
                int offset = BitConverter.ToInt32(ico, sourceEntry + 12);
                int resourceId = BitConverter.ToUInt16(group, targetEntry + 12);
                byte[] image = ReadResource(module, new IntPtr(resourceId), 3);

                if (image.Length != length) throw new InvalidDataException("Icon frame size changed.");

                for (int i = 0; i < length; i++)
                {
                    if (image[i] != ico[offset + i]) throw new InvalidDataException("Icon frame pixels changed.");
                }
            }

            return count;
        }
        finally { FreeLibrary(module); }
    }
}
'@

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('Audio Switcher build tests ' + [Guid]::NewGuid().ToString('N'))
$powershell = Join-Path $PSHOME 'powershell.exe'
$count = 0

function Invoke-TestBuild {
    param([bool]$ShouldSucceed)
    $output = & $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $temporary 'BuildHarness.ps1') 2>&1
    $result = $LASTEXITCODE

    if (($result -eq 0) -ne $ShouldSucceed) {
        throw ('Unexpected build result ({0}): {1}' -f $result, ($output -join "`n"))
    }

    $script:count++
}

function Assert-ExecutablePreserved {
    param([string]$ExpectedHash)
    $actualHash = (Get-FileHash -LiteralPath (Join-Path $temporary 'AudioSwitcher.exe') -Algorithm SHA256).Hash

    if ($actualHash -ne $ExpectedHash) { throw 'A failed build replaced the working executable.' }

    $script:count++
}

try {
    [void](New-Item -ItemType Directory -Path (Join-Path $temporary 'assets/icons') -Force)
    Copy-Item -LiteralPath (Join-Path $root 'Launcher.cs') -Destination $temporary
    Copy-Item -LiteralPath (Join-Path $root 'CoreAudio.cs') -Destination $temporary
    $icon = Join-Path $temporary 'assets/icons/icon_round.ico'
    Copy-Item -LiteralPath (Join-Path $root 'assets/icons/icon_round.ico') -Destination $icon
    $harness = ($functionNodes | ForEach-Object { $_.Extent.Text }) -join "`r`n`r`n"
    $harness += @'

try {
    $ErrorActionPreference = 'Stop'
    $built = Build-NoConsoleLauncher
    Write-Output $built
    exit 0
}
catch {
    Write-Output $_.Exception.Message
    exit 1
}
'@
    Set-Content -LiteralPath (Join-Path $temporary 'BuildHarness.ps1') -Value $harness -Encoding UTF8
    Invoke-TestBuild $true
    $executable = Join-Path $temporary 'AudioSwitcher.exe'
    $frames = [AudioSwitcherResourceTest]::Verify($executable, $icon)
    $count++

    # Exercise replacement of an existing executable, not only first installation.
    Invoke-TestBuild $true
    [void][AudioSwitcherResourceTest]::Verify($executable, $icon)
    $count++
    $hash = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash

    # Compile the real audio bridge, but never invoke it or activate COM.
    Add-Type -LiteralPath (Join-Path $temporary 'CoreAudio.cs') -OutputAssembly (Join-Path $temporary 'CoreAudio-test.dll')
    $count++

    Remove-Item -LiteralPath $icon
    Invoke-TestBuild $false
    Assert-ExecutablePreserved $hash
    [IO.File]::WriteAllBytes($icon, [byte[]]@(0, 1, 2, 3, 4, 5))
    Invoke-TestBuild $false
    Assert-ExecutablePreserved $hash
    Copy-Item -LiteralPath (Join-Path $root 'assets/icons/icon_round.ico') -Destination $icon -Force
    Set-Content -LiteralPath (Join-Path $temporary 'Launcher.cs') -Value 'This is not valid C#.' -Encoding UTF8
    Invoke-TestBuild $false
    Assert-ExecutablePreserved $hash
    Write-Host "OK: $count build checks; $frames embedded icon frames match the source byte for byte. No audio or desktop shortcuts were accessed."
}
finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}

# The last child compiler check intentionally fails; report the suite result.
exit 0
