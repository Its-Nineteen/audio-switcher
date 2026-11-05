# Audio Switcher

A small Windows utility that switches once between two playback profiles and exits. Each profile has a general output and an independent communications output, or **Keep unchanged** for communications. Microphones and other capture devices are never changed.

The normal desktop shortcut launches a locally built executable without a console window or an initial console flash. Successful switches are silent; errors appear in a dialog. There is no tray app, background observer, service, startup entry, scheduled task, telemetry, or runtime download.

This is an unofficial project, not affiliated with Logitech or Astro.

## Requirements

- Windows 10 or 11, Windows PowerShell 5.1, and .NET Framework.
- Two different active playback outputs.
- A permanent folder you can write to, including when building or saving settings.

No administrator rights, Visual Studio, PowerShell 7, or downloaded PowerShell modules are required. Security policies on a managed computer may restrict compilation or execution. The locally built launcher is unsigned; errors are reported rather than changing system protections.

## First setup

1. Download the repository ZIP and extract all files into a permanent folder, or clone the repository there. Keep the `assets/icons/` directory intact. Paths containing spaces are supported.
2. Connect and enable both outputs. For an A50 X setup, put the base in PC mode.
3. Open `Setup.cmd`. Choose general outputs A and B, then choose the communications playback output separately for each profile. Enter `0` to keep communications unchanged. Press Enter to accept a suggestion, or `q` to cancel.
4. Setup compiles `AudioSwitcher.exe`, saves `audio-config.json`, and creates the **Audio Switcher** desktop shortcut. Setup does not change your current audio output.
5. Open that shortcut whenever you want to switch, or open `AudioSwitcher.exe` directly.

Suggested A50 X configuration:

| Profile | Console and Multimedia playback | Communications playback |
| --- | --- | --- |
| A: headset | A50 X Game | A50 X Voice |
| B: speakers | Your selected speakers | The same speakers |

These are suggestions, not required device names. Windows device names are displayed unchanged, including on non-English systems. Setup recognizes both `Speakers` and `Altavoces` when suggesting a speaker output. It saves endpoint IDs, not list positions or name matches.

## Switching behavior

Audio Switcher reads the real Windows **Console** default each time. If it is A, the target is B. If it is B, a third output, or there is no default, the target is A. There is no saved click counter.

The target general output is assigned to the Console and Multimedia playback roles. The target communications output is assigned to the Communications playback role unless that profile uses **Keep unchanged**. Game and Voice therefore stay separate when configured that way.

All required target outputs are validated before any change. If an output is missing, the operation fails without starting a partial switch. If a device disconnects or Windows rejects a change during the operation, the utility tries to restore the previous defaults and reports any incomplete restoration. The underlying calls are not an atomic transaction. Overlapping invocations are ignored using the same mutex as the earlier version.

Volume, EQ, formats, device names, drivers, microphones, and application preferences are untouched. The utility does not depend on Logitech G HUB, battery level, or base detection.

### Applications and console audio

Only Windows defaults change. An application explicitly pinned to A50 X Voice or another device keeps that choice. To follow these profiles, an application must use the appropriate Windows default and support changes during playback. Its “default” option may mean general playback or communications; check the application's settings.

Audio Switcher does not control the base's mixer or redirect a console's HDMI audio to the PC speakers.

## Build or rebuild locally

`Setup.cmd` builds the launcher during configuration. To rebuild the executable and update the desktop shortcut **without rewriting your configuration or changing audio**, open Windows PowerShell in the project folder and run:

```powershell
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File ".\AudioSwitcher.ps1" -Build
```

The build uses the compiler supplied with Windows PowerShell 5.1/.NET Framework. It produces a Windows GUI executable and embeds `assets/icons/icon_round.ico` as its Win32 icon resource. Compilation happens at a temporary path before replacing an existing executable. Missing or invalid build inputs report an error; a failed compilation leaves the previous executable in place.

The launcher starts a short-lived Windows PowerShell child with `UseShellExecute = false` and `CreateNoWindow = true`. It reads stdout and stderr concurrently and waits for completion. Neither process remains after the operation or its error dialog has finished. The script path is passed with `-File`, not evaluated as a `-Command` string.

The supplied commands use a process-scoped execution policy; they do not change your global policy or override enforced organization policies.

## Update an existing v2 installation

1. Finish any switch or setup operation and close its windows. Make a copy of the installation folder before replacing files.
2. Copy the new repository files, including `assets/icons/`, into that installation folder. Keep your existing `audio-config.json`. The repository does not include a personal configuration file.
3. Run the `-Build` command above from that folder. This leaves your v2 settings, endpoint IDs, and Game/Voice choices intact. The configuration schema remains `Version = 2`.
4. Use **Audio Switcher.lnk** or `AudioSwitcher.exe`. The known legacy **Alternar audio.lnk** is migrated only when it belongs to this installation. Unrelated shortcuts are left alone.
5. Remove old Start menu or taskbar pins and pin the new shortcut again. Old pins can still point at the former executable or a console command.
6. Once the new shortcut works, you may remove obsolete `AlternarAudio.exe`, `AlternarAudio.ps1`, `Lanzador.cs`, `Configurar.cmd`, `Listar.cmd`, `Probar.cmd`, `LEEME.txt`, and `pruebas/` from the old installation. Do not remove your configuration or backups.

If you use a new folder instead, copy your existing `audio-config.json` there before building. Shortcuts that belong to the old folder must be updated or removed manually.

Run `Setup.cmd` only when you want to change device choices or recover from changed endpoint IDs. It suggests existing choices and makes a dated backup before saving a replacement configuration. A v1 configuration requires setup to select communications behavior for both profiles. The new script accepts the former parameter names `-Configurar`, `-Listar`, `-Silencioso`, and `-DesdeLanzador` as aliases; automation should use the new script filename.

## Icons

All three supplied multiresolution icons are included unchanged:

| File | Use |
| --- | --- |
| `assets/icons/icon_round.ico` | Embedded executable icon and default shortcut icon |
| `assets/icons/icon_transparent.ico` | Optional transparent shortcut icon |
| `assets/icons/icon_gamer.ico` | Optional original shortcut icon |

To use an alternative, right-click the desktop shortcut, select **Properties → Shortcut → Change Icon**, and browse to the ICO file. This changes the shortcut icon only; the executable keeps the round icon. Rebuilding preserves a custom shortcut icon.

Explorer and pinned shortcuts can cache icons. If an old icon remains, refresh Explorer and recreate the relevant pin from the updated shortcut. Check `AudioSwitcher.exe` directly in the project folder as well. The utility does not clear system icon caches or remove unrelated pins.

## Diagnostics and tests

| Entry point | Behavior |
| --- | --- |
| `AudioSwitcher.exe` / desktop shortcut | Switches once without a console; dialog only on error |
| `Setup.cmd` | Visible configuration wizard; builds the launcher |
| `ListDevices.cmd` | Lists active playback outputs and all three defaults; does not switch |
| `TestSwitch.cmd` | **Changes audio** once and prints the selected profile and outputs in a visible console |

Use `ListDevices.cmd` to inspect availability. If an endpoint is missing, check its connection, enablement, and base mode; rerun setup if its ID has changed. Keep native Windows error details when diagnosing failures: those details may appear in the Windows display language.

Run the automatic checks in Windows PowerShell from the project folder:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\tests\Test-Logic.ps1"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\tests\Test-CoreAudio.ps1"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\tests\Test-Build.ps1"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\tests\Test-Shortcut.ps1"
```

These checks do not switch real audio. The logic checks extract functions from the script instead of executing its entry point. The Core Audio checks exercise the real profile and recovery methods with simulated devices and a simulated policy object. The build checks compile in a temporary directory, including a path with spaces, and inspect the executable's subsystem and embedded icon. The shortcut checks use a temporary folder, leaving your actual desktop untouched.

### Manual Windows acceptance check

Perform this separately when changing your actual output is convenient:

1. Run `ListDevices.cmd` and note the current playback defaults. Separately note your microphone selection in Windows sound settings.
2. Open the executable directly in Explorer and check its round icon. Check the shortcut icon too.
3. Click the shortcut twice. Confirm A → B → A, the configured Game/Voice separation, and unchanged microphones. Check that neither click causes a console flash or a success dialog.
4. Select a third playback output in Windows, then click once and confirm that A is selected. If convenient, also check a profile with **Keep unchanged**.
5. With a required target output disconnected, confirm that an error is shown before any available output changes.
6. After success, or after dismissing an error dialog, check Task Manager for lingering launcher or child PowerShell processes.

Automatic tests cannot establish device compatibility, visual appearance in Explorer, or absence of a console flash on your machine. Applications that ignore Windows default-device changes may need their own output changed manually.

## Source layout and implementation

| Path | Purpose |
| --- | --- |
| `AudioSwitcher.ps1` | Configuration, profile selection, local build, and desktop shortcut |
| `CoreAudio.cs` | Windows Core Audio interop and playback-only default changes |
| `Launcher.cs` | GUI-subsystem launcher with no console |
| `Setup.cmd`, `ListDevices.cmd`, `TestSwitch.cmd` | Visible Windows PowerShell entry points |
| `assets/icons/` | Three approved ICO assets |
| `tests/` | Automated checks that do not change real audio |

The project uses Core Audio to enumerate playback endpoints and read defaults. It retains `IPolicyConfig::SetDefaultEndpoint` to set them. `IPolicyConfig` is not a publicly documented Microsoft interface, and future Windows compatibility is not guaranteed. The implementation does not enumerate capture endpoints or change registry settings directly.

Generated executables, shortcuts, `audio-config.json`, its dated backups, logs, and build temporaries are local files excluded from Git. Do not publish your device IDs or personal configuration when reporting an issue.

The same checks run in GitHub Actions using Windows PowerShell 5.1.

## Uninstall

Remove the desktop shortcut, any pins you created, and the installation folder. Keep a copy of `audio-config.json` if you want to reuse the profiles later. Your last selected audio defaults remain in Windows and can be changed normally in Windows settings. There is no service or startup entry to remove.
