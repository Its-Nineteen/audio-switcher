// Audio Switcher: GUI-subsystem launcher. Compiled locally by Setup.cmd.
// It never creates a console; PowerShell is a short-lived child with CREATE_NO_WINDOW.
// No elevated privileges, network, scheduler, service or startup registration.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;

[assembly: AssemblyTitle("Audio Switcher")]
[assembly: AssemblyProduct("Audio Switcher")]
[assembly: AssemblyDescription("Switch between Windows playback and communications profiles")]

namespace AudioSwitcherLauncher
{
    internal static class Program
    {
        [STAThread]
        private static int Main()
        {
            try
            {
                string directory = AppDomain.CurrentDomain.BaseDirectory;
                string script = Path.Combine(directory, "AudioSwitcher.ps1");

                if (!File.Exists(script))
                    throw new FileNotFoundException("AudioSwitcher.ps1 was not found. Keep the executable alongside the other application files.");

                string powershell = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.System),
                    @"WindowsPowerShell\v1.0\powershell.exe");

                if (!File.Exists(powershell))
                    throw new FileNotFoundException("Windows PowerShell 5.1 was not found.");

                var start = new ProcessStartInfo
                {
                    FileName = powershell,
                    // A Windows file path cannot contain a double quote. -File is used,
                    // not -Command: paths are not interpreted as PowerShell code.
                    Arguments = "-NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File \""
                        + script + "\" -FromLauncher",
                    WorkingDirectory = directory,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    StandardOutputEncoding = Encoding.UTF8,
                    StandardErrorEncoding = Encoding.UTF8
                };

                using (Process process = Process.Start(start))
                {
                    if (process == null)
                        throw new InvalidOperationException("Windows could not start Audio Switcher.");

                    // Drain BOTH streams concurrently to avoid a full-pipe deadlock.
                    Task<string> stdout = process.StandardOutput.ReadToEndAsync();
                    Task<string> stderr = process.StandardError.ReadToEndAsync();
                    process.WaitForExit();
                    string output = stdout.GetAwaiter().GetResult();
                    string error = stderr.GetAwaiter().GetResult();

                    if (process.ExitCode != 0)
                    {
                        string detail = !String.IsNullOrWhiteSpace(error) ? error.Trim() : output.Trim();

                        if (String.IsNullOrWhiteSpace(detail))
                            detail = "The switch did not complete. Run TestSwitch.cmd for diagnostic details.";

                        if (detail.Length > 3500) detail = detail.Substring(0, 3500) + "\n...";

                        ShowError(detail);
                    }

                    return process.ExitCode;
                }
            }
            catch (Exception ex)
            {
                ShowError(ex.GetBaseException().Message);
                return 1;
            }
        }

        private static void ShowError(string message)
        {
            MessageBox.Show(message, "Audio Switcher - Error",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
