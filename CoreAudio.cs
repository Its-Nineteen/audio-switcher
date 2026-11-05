// Audio Switcher: Windows Core Audio interop. No services, hooks or network access.
// Target: Windows PowerShell 5.1 / .NET Framework (C# 5 compatible).
// MMDevice / property store references: https://learn.microsoft.com/windows/win32/coreaudio/device-properties
// PolicyConfig is an undocumented interface, not a supported public Windows contract.
// Its method order is also used by: https://github.com/frgnca/AudioDeviceCmdlets
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace AudioSwitcher
{
    public sealed class OutputDevice
    {
        public string Id { get; set; }
        public string Name { get; set; }
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct PropertyKey
    {
        public Guid FormatId;
        public uint PropertyId;
        public PropertyKey(Guid formatId, uint propertyId)
        { FormatId = formatId; PropertyId = propertyId; }
    }

    // This union has the required native size on both x86 (16) and x64 (24).
    [StructLayout(LayoutKind.Sequential)]
    internal struct CountedPointer { public uint Count; public IntPtr Pointer; }
    [StructLayout(LayoutKind.Explicit)]
    internal struct PropVariant
    {
        [FieldOffset(0)] public ushort Type;
        [FieldOffset(8)] public IntPtr Pointer;
        [FieldOffset(8)] public CountedPointer SizeUnion;
    }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int flow, uint state, out IDeviceCollection devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IDevice device);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IDevice device);
        [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr callback);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr callback);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IDeviceCollection
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int Item(uint index, out IDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IDevice
    {
        [PreserveSig] int Activate(ref Guid iid, uint context, IntPtr parameters, out IntPtr result);
        [PreserveSig] int OpenPropertyStore(uint access, out IPropertyStore properties);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out uint state);
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPropertyStore
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }

    // Preserve all slots before SetDefaultEndpoint. These preceding methods are NOT used.
    [ComImport, Guid("F8679F50-850A-41CF-9C72-430F290290C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPolicyConfig
    {
        [PreserveSig] int GetMixFormat([MarshalAs(UnmanagedType.LPWStr)] string id, out IntPtr format);
        [PreserveSig] int GetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id, int useDefault, out IntPtr format);
        [PreserveSig] int ResetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id);
        [PreserveSig] int SetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr endpoint, IntPtr mix);
        [PreserveSig] int GetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string id, int useDefault, out long period, out long minimum);
        [PreserveSig] int SetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string id, ref long period);
        [PreserveSig] int GetShareMode([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr mode);
        [PreserveSig] int SetShareMode([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr mode);
        [PreserveSig] int GetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string id, int fxStore, ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string id, int fxStore, ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, int role);
        [PreserveSig] int SetEndpointVisibility([MarshalAs(UnmanagedType.LPWStr)] string id, int visible);
    }

    public static class Audio
    {
        [DllImport("ole32.dll")] private static extern int PropVariantClear(ref PropVariant value);
        private static readonly Guid EnumeratorClass = new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E");
        private static readonly Guid PolicyClass = new Guid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9");

        private static void Check(int result)
        { if (result < 0) Marshal.ThrowExceptionForHR(result); }

        private static void Release(object value)
        { if (value != null && Marshal.IsComObject(value)) Marshal.ReleaseComObject(value); }

        private static IDeviceEnumerator NewEnumerator()
        { return (IDeviceEnumerator)Activator.CreateInstance(Type.GetTypeFromCLSID(EnumeratorClass)); }

        public static OutputDevice[] GetOutputs()
        {
            IDeviceEnumerator enumerator = null;
            IDeviceCollection devices = null;
            var result = new List<OutputDevice>();

            try
            {
                enumerator = NewEnumerator();
                Check(enumerator.EnumAudioEndpoints(0, 1, out devices)); // eRender, DEVICE_STATE_ACTIVE
                uint count;
                Check(devices.GetCount(out count));

                for (uint i = 0; i < count; i++)
                {
                    IDevice device = null;
                    IPropertyStore properties = null;
                    PropVariant value = new PropVariant();

                    try
                    {
                        Check(devices.Item(i, out device));
                        string id;
                        Check(device.GetId(out id));
                        Check(device.OpenPropertyStore(0, out properties)); // read only
                        var key = new PropertyKey(new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0"), 14);
                        Check(properties.GetValue(ref key, out value));
                        string name = (value.Type == 31 && value.Pointer != IntPtr.Zero)
                            ? Marshal.PtrToStringUni(value.Pointer) : id; // VT_LPWSTR
                        result.Add(new OutputDevice { Id = id, Name = name });
                    }
                    finally
                    {
                        PropVariantClear(ref value);
                        Release(properties);
                        Release(device);
                    }
                }

                return result.ToArray();
            }
            finally { Release(devices); Release(enumerator); }
        }

        // role: 0 = Console, 1 = Multimedia, 2 = Communications. Playback only.
        public static string GetDefaultId(int role)
        {
            if (role < 0 || role > 2) throw new ArgumentOutOfRangeException("role");

            IDeviceEnumerator enumerator = null;
            IDevice device = null;

            try
            {
                enumerator = NewEnumerator();
                int hr = enumerator.GetDefaultAudioEndpoint(0, role, out device);

                if (hr == unchecked((int)0x80070490)) return null; // no default endpoint

                Check(hr);
                string id;
                Check(device.GetId(out id));
                return id;
            }
            finally { Release(device); Release(enumerator); }
        }

        // Backward-compatible entry point for v1 callers.
        public static void SetPlaybackDefaults(string id, bool includeCommunications)
        {
            SetPlaybackProfile(id, includeCommunications ? id : null);
        }

        // Playback and communications may be DIFFERENT render endpoints.
        // communicationsId == null means preserve the current communications default.
        // Capture endpoints (microphones) are NEVER modified.
        public static void SetPlaybackProfile(string playbackId, string communicationsId)
        {
            if (String.IsNullOrWhiteSpace(playbackId))
                throw new ArgumentException("A playback output is required.", "playbackId");

            if (communicationsId != null && String.IsNullOrWhiteSpace(communicationsId))
                throw new ArgumentException("The communications output is invalid.", "communicationsId");

            var active = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            foreach (OutputDevice device in GetOutputs()) active.Add(device.Id);

            // Preflight ALL requested destinations before touching any default.
            if (!active.Contains(playbackId))
                throw new InvalidOperationException("The selected playback output is unavailable.");

            if (communicationsId != null && !active.Contains(communicationsId))
                throw new InvalidOperationException("The selected communications output is unavailable. No outputs have been changed.");

            string[] previous = new string[3];

            for (int role = 0; role < 3; role++) previous[role] = GetDefaultId(role);

            string[] requested = new string[] {
                playbackId, playbackId, communicationsId ?? previous[2]
            };

            object instance = null;
            IPolicyConfig policy = null;
            bool attemptedChange = false;

            try
            {
                instance = Activator.CreateInstance(Type.GetTypeFromCLSID(PolicyClass));
                policy = (IPolicyConfig)instance;
                // Communications LAST: select Voice for headphones, or speakers for
                // the speaker profile. Keep means reassert its previous value.
                for (int role = 0; role < 3; role++)
                {
                    if (String.IsNullOrEmpty(requested[role])) continue;

                    attemptedChange = true;
                    Check(policy.SetDefaultEndpoint(requested[role], role));
                }

                // Fail visibly instead of reporting success with a partially applied profile.
                for (int role = 0; role < 3; role++)
                {
                    if (!String.IsNullOrEmpty(requested[role]) &&
                        !String.Equals(GetDefaultId(role), requested[role], StringComparison.OrdinalIgnoreCase))
                        throw new InvalidOperationException("Windows did not retain the requested audio profile.");
                }
            }
            catch (Exception ex)
            {
                if (policy == null || !attemptedChange) throw;

                // Best-effort rollback of all render roles. No microphone changes.
                bool restored = true;

                for (int role = 0; role < 3; role++)
                {
                    if (String.IsNullOrEmpty(previous[role]))
                    {
                        restored = false; // Clearing a default is not supported here.
                        continue;
                    }

                    try { if (policy.SetDefaultEndpoint(previous[role], role) < 0) restored = false; }
                    catch { restored = false; }
                }

                for (int role = 0; role < 3 && restored; role++)
                {
                    try { restored = String.Equals(GetDefaultId(role), previous[role], StringComparison.OrdinalIgnoreCase); }
                    catch { restored = false; }
                }

                string recovery = restored
                    ? "The previous outputs have been restored."
                    : "A complete restoration could not be confirmed. Check the outputs in Windows.";
                throw new InvalidOperationException("The audio profile could not be applied. " + recovery + " " + ex.Message, ex);
            }
            finally { Release(instance); }
        }
    }
}
