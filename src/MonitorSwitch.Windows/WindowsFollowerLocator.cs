using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;
using MonitorSwitch.Core;
using static MonitorSwitch.Windows.NativeMethods;

namespace MonitorSwitch.Windows;

/// <summary>Fresh HID collection discovery, shared handles, exact product/path hash identity.</summary>
public sealed class WindowsFollowerLocator(IClock clock) : IFollowerLocator
{
    public IReadOnlyList<FollowerIdentity> Discover() => Inventory().Select(d => d.Identity).ToArray();

    public IFollowerSession OpenUnique(FollowerIdentity identity)
    {
        var matches = Inventory().Where(d => d.Identity == identity).ToArray();
        if (matches.Length != 1) throw new TargetUnavailableException("Follower missing or ambiguous.");
        var handle = HidNative.CreateFile(matches[0].Path, 0xC0000000, 3, IntPtr.Zero, 3, 0x40000000, IntPtr.Zero);
        if (handle.IsInvalid)
        {
            handle.Dispose();
            throw new TargetUnavailableException("Follower could not be opened in shared mode.");
        }
        try
        {
            // Check the opened handle too; never trust a stale inventory entry.
            if (!TryIdentity(handle, matches[0].Path, out var actual) || actual != identity)
                throw new TargetUnavailableException("Follower identity changed while opening.");
            var stream = new FileStream(handle, FileAccess.ReadWrite, bufferSize: 1, isAsync: true);
            return new HidppSession(new WindowsHidppTransport(stream), clock);
        }
        catch { handle.Dispose(); throw; }
    }

    private sealed record Device(string Path, FollowerIdentity Identity);

    private static List<Device> Inventory()
    {
        if (Marshal.SizeOf<HidNative.Attributes>() != 12 || Marshal.SizeOf<HidNative.Caps>() != 64
            || Marshal.SizeOf<DeviceInterfaceData>() != (IntPtr.Size == 8 ? 32 : 28))
            throw new PlatformNotSupportedException("Unexpected HID interop layout.");
        HidNative.HidD_GetHidGuid(out var guid);
        var set = SetupDiGetClassDevs(ref guid, IntPtr.Zero, IntPtr.Zero, DigcfPresent | DigcfDeviceInterface);
        if (set == InvalidHandleValue) throw new IOException("HID discovery failed.");
        var found = new List<Device>();
        try
        {
            for (uint i = 0; ; i++)
            {
                var data = new DeviceInterfaceData { Size = (uint)Marshal.SizeOf<DeviceInterfaceData>() };
                if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref guid, i, ref data))
                {
                    if (Marshal.GetLastPInvokeError() != 259) throw new IOException("HID enumeration failed.");
                    break;
                }
                var info = new DevInfoData { Size = (uint)Marshal.SizeOf<DevInfoData>() };
                SetupDiGetDeviceInterfaceDetail(set, ref data, IntPtr.Zero, 0, out var required, ref info);
                if (required is < 6 or > 65536) throw new IOException("Invalid HID interface detail size.");
                var buffer = Marshal.AllocHGlobal((int)required);
                try
                {
                    Marshal.WriteInt32(buffer, IntPtr.Size == 8 ? 8 : 6);
                    if (!SetupDiGetDeviceInterfaceDetail(set, ref data, buffer, required, out _, ref info))
                        throw new IOException("HID interface detail unavailable.");
                    var path = Marshal.PtrToStringUni(buffer + 4) ?? throw new IOException("HID path unavailable.");
                    // Metadata only: no reports are sent by discovery.
                    using var handle = HidNative.CreateFile(path, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
                    if (!handle.IsInvalid && TryIdentity(handle, path, out var identity)) found.Add(new(path, identity!));
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
        }
        finally { SetupDiDestroyDeviceInfoList(set); }
        return found;
    }

    private static bool TryIdentity(SafeFileHandle handle, string path, out FollowerIdentity? identity)
    {
        identity = null;
        var attributes = new HidNative.Attributes { Size = Marshal.SizeOf<HidNative.Attributes>() };
        if (!HidNative.HidD_GetAttributes(handle, ref attributes) || attributes.VendorId != 0x046D) return false;
        if (!HidNative.HidD_GetPreparsedData(handle, out var preparsed)) return false;
        try
        {
            if (HidNative.HidP_GetCaps(preparsed, out var caps) != 0x00110000
                || caps.UsagePage != 0xFF43 || caps.Usage != 0x0202
                || caps.InputReportByteLength != 20 || caps.OutputReportByteLength != 20) return false;
            // Windows paths are case-insensitive. Freeze this normalization for future enrollments.
            var hash = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(path.ToUpperInvariant())));
            identity = new(attributes.ProductId.ToString("X4"), hash);
            return true;
        }
        finally { HidNative.HidD_FreePreparsedData(preparsed); }
    }
}

internal sealed class WindowsHidppTransport(FileStream stream) : IHidppTransport
{
    public void Write(byte[] report, TimeSpan timeout)
    {
        if (report.Length != 20 || report[0] != 0x11 || report[1] != 0xFF)
            throw new ArgumentException("Only HID++ long reports for directly connected devices are supported.");
        using var cancel = new CancellationTokenSource(timeout);
        try { stream.WriteAsync(report.AsMemory(), cancel.Token).AsTask().GetAwaiter().GetResult(); }
        catch (OperationCanceledException) { throw new TimeoutException("HID write timed out; outcome uncertain."); }
        catch (IOException error) { throw Translate(error); }
    }

    public byte[] Read(TimeSpan timeout)
    {
        using var cancel = new CancellationTokenSource(timeout);
        var report = new byte[20];
        try
        {
            var length = stream.ReadAsync(report.AsMemory(), cancel.Token).AsTask().GetAwaiter().GetResult();
            if (length == 0) throw new HidppIoException(null);
            return report.AsSpan(0, length).ToArray();
        }
        catch (OperationCanceledException) { throw new TimeoutException("HID read timed out."); }
        catch (IOException error) { throw Translate(error); }
    }

    private static IOException Translate(IOException error)
    {
        if (error is HidppIoException) return error;
        int? code = (error.HResult & 0xFFFF0000) == 0x80070000 ? error.HResult & 0xFFFF : null;
        return code == 1167 ? new FollowerDisconnectedException() : new HidppIoException(code);
    }

    // Cancellation is awaited to completion, never detached. Keep the process lock until I/O is quiescent.
    public void Dispose() => stream.Dispose();
}

internal static class HidNative
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct Attributes { public int Size; public ushort VendorId, ProductId, VersionNumber; }

    [StructLayout(LayoutKind.Sequential)]
    internal struct Caps
    {
        public ushort Usage, UsagePage, InputReportByteLength, OutputReportByteLength, FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public ushort[] Reserved;
        public ushort NumberLinkCollectionNodes, NumberInputButtonCaps, NumberInputValueCaps, NumberInputDataIndices;
        public ushort NumberOutputButtonCaps, NumberOutputValueCaps, NumberOutputDataIndices;
        public ushort NumberFeatureButtonCaps, NumberFeatureValueCaps, NumberFeatureDataIndices;
    }

    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security,
        uint creation, uint flags, IntPtr template);
    [DllImport("hid.dll")]
    internal static extern void HidD_GetHidGuid(out Guid guid);
    [DllImport("hid.dll")]
    [return: MarshalAs(UnmanagedType.U1)]
    internal static extern bool HidD_GetAttributes(SafeFileHandle handle, ref Attributes attributes);
    [DllImport("hid.dll")]
    [return: MarshalAs(UnmanagedType.U1)]
    internal static extern bool HidD_GetPreparsedData(SafeFileHandle handle, out IntPtr data);
    [DllImport("hid.dll")]
    [return: MarshalAs(UnmanagedType.U1)]
    internal static extern bool HidD_FreePreparsedData(IntPtr data);
    [DllImport("hid.dll")]
    internal static extern int HidP_GetCaps(IntPtr data, out Caps caps);
}
