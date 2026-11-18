namespace MonitorSwitch.Core;

public sealed record FollowerConfig(string Name, string ProductId, string DevicePathHash, int AwayChannel, string AwayHostName);
public sealed record FollowConfig(uint AwayInput, FollowerConfig[] Devices);
public sealed record FollowerIdentity(string ProductId, string DevicePathHash);
public sealed record HostState(int SlotCount, int CurrentChannel);
public sealed record HostSlot(int Channel, bool Paired, string? HostName);
public sealed record FollowerResult(string Name, string Preflight, bool CommandSent, string Observation,
    string SendResult = "NotSent", FollowerDiagnostics? Diagnostics = null);
// Only protocol metadata/counters, never raw reports, paths or host names.
public sealed record FollowerDiagnostics(byte? ChangeHostIndex, byte? ChangeHostVersion, byte? HostsInfoIndex,
    int? LastCurrentChannel, int StateReplies, int Timeouts, int IoFailures,
    int? LastNativeError, byte? LastQueryError, byte? ChangeHostError);

public static class FollowerValidation
{
    public static bool IsProductId(string? value) => value is { Length: 4 } && value.All(char.IsAsciiHexDigit);
    public static bool IsName(string? value) => value is { Length: > 0 and <= 64 }
        && value.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_');
    public static bool IsHostName(string? value) => !string.IsNullOrWhiteSpace(value)
        && !value.Contains('<') && !value.Contains('>') && !value.Any(char.IsControl)
        && value.Length <= 255;

    public static void Validate(FollowConfig follow)
    {
        if (!DeviceProfile.Allows(follow.AwayInput) || follow.Devices is not { Length: >= 1 and <= 4 })
            throw new ConfigurationException("follow requires input 5/6 and one to four devices.");
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var identities = new HashSet<FollowerIdentity>();
        foreach (var device in follow.Devices)
        {
            if (device is null || !IsName(device.Name) || !names.Add(device.Name)
                || !IsProductId(device.ProductId) || !Edid.IsIdentityHash(device.DevicePathHash)
                || device.AwayChannel is < 1 or > 3 || !IsHostName(device.AwayHostName)
                || !identities.Add(new(device.ProductId.ToUpperInvariant(), device.DevicePathHash)))
                throw new ConfigurationException("Invalid or duplicate follower enrollment.");
        }
    }
}

public interface IFollowerLocator
{
    // Only Logitech 046D, usage page FF43 / usage 0202, long-report collections.
    IReadOnlyList<FollowerIdentity> Discover();
    // Re-enumerate and require one exact product/path-hash match. No enumeration-order fallback.
    IFollowerSession OpenUnique(FollowerIdentity identity);
}

public interface IFollowerSession : IDisposable
{
    FollowerDiagnostics? Diagnostics => null;
    HostState ReadState();
    HostSlot ReadHost(int channel);
    void ChangeHost(int channel);
    // Bounded by the supplied budget; silence alone is Unknown, explicit disconnect is Left.
    string ObserveDeparture(TimeSpan budget);
}

public sealed class FollowerDisconnectedException() : IOException("Follower disconnected.");
public sealed class HidppIoException(int? nativeError) : IOException("HID I/O failed.")
{
    public int? NativeError { get; } = nativeError;
}
public sealed class HidppQueryException(byte errorCode) : IOException("HID++ query rejected.")
{
    public byte ErrorCode { get; } = errorCode;
}

/// <summary>Caller holds the operation lock. No state store: followers never become recovery authority.</summary>
public sealed class FollowerCoordinator(IFollowerLocator locator)
{
    public IReadOnlyList<FollowerResult> Run(FollowConfig config, bool dryRun)
    {
        FollowerValidation.Validate(config);
        var devices = config.Devices.OrderBy(d => d.ProductId.Equals("B359", StringComparison.OrdinalIgnoreCase) ? 0
            : d.ProductId.Equals("B031", StringComparison.OrdinalIgnoreCase) ? 2 : 1).ToArray();
        var sessions = new IFollowerSession?[devices.Length];
        var results = devices.Select(d => new FollowerResult(d.Name, "NotChecked", false, "NotSent")).ToArray();
        try
        {
            // Hold all opened sessions until the complete operation finishes.
            for (var i = 0; i < devices.Length; i++)
            {
                var d = devices[i];
                try
                {
                    var session = sessions[i] = locator.OpenUnique(new(d.ProductId.ToUpperInvariant(), d.DevicePathHash));
                    var state = session.ReadState();
                    if (state.SlotCount is < 1 or > 3 || state.CurrentChannel < 1 || state.CurrentChannel > state.SlotCount
                        || d.AwayChannel > state.SlotCount)
                        results[i] = results[i] with { Preflight = "InvalidChannels" };
                    else if (state.CurrentChannel == d.AwayChannel)
                        results[i] = results[i] with { Preflight = "AlreadyThere", Observation = "AlreadyThere" };
                    else
                    {
                        var slot = session.ReadHost(d.AwayChannel);
                        results[i] = results[i] with { Preflight = slot.Channel != d.AwayChannel ? "InvalidChannel"
                            : !slot.Paired ? "Unpaired" : slot.HostName != d.AwayHostName ? "HostMismatch" : "Ready" };
                    }
                }
                catch (Exception error) when (error is not OutOfMemoryException)
                {
                    // Do not copy exception messages: native errors can contain private paths/host names.
                    results[i] = results[i] with { Preflight = error is TargetUnavailableException ? "MissingOrAmbiguous" : "Unavailable" };
                }
                results[i] = results[i] with { Diagnostics = sessions[i]?.Diagnostics };
            }
            if (results.Any(r => r.Preflight is not ("Ready" or "AlreadyThere"))) return results;
            if (dryRun) return results.Select(r => r.Preflight == "Ready" ? r with { Observation = "WouldSend" } : r).ToArray();

            for (var i = 0; i < devices.Length; i++)
            {
                if (results[i].Preflight == "AlreadyThere") continue;
                // Mark before entering native code: a thrown/failed write may still have changed the host.
                results[i] = results[i] with { CommandSent = true, SendResult = "Unverified", Observation = "Unknown" };
                try
                {
                    sessions[i]!.ChangeHost(devices[i].AwayChannel);
                    results[i] = results[i] with { SendResult = "Accepted" };
                }
                catch (Exception error) when (error is not OutOfMemoryException) { }
            }
            for (var i = 0; i < devices.Length; i++)
            {
                if (!results[i].CommandSent) continue;
                try
                {
                    var observation = sessions[i]!.ObserveDeparture(TimeSpan.FromSeconds(2));
                    results[i] = results[i] with { Observation = observation is "Left" or "StillHere" ? observation : "Unknown" };
                }
                catch (Exception error) when (error is not OutOfMemoryException) { }
                results[i] = results[i] with { Diagnostics = sessions[i]?.Diagnostics };
                if (results[i].Diagnostics?.ChangeHostError is not null)
                    results[i] = results[i] with { SendResult = "Rejected" };
            }
            return results;
        }
        finally
        {
            foreach (var session in sessions)
            {
                try { session?.Dispose(); }
                catch (Exception error) when (error is not OutOfMemoryException) { }
            }
        }
    }

    public static bool Succeeded(IReadOnlyList<FollowerResult> results, bool dryRun = false) =>
        results.Count > 0 && results.All(r => r.SendResult != "Rejected"
            && (r.Observation is "Left" or "AlreadyThere" || (dryRun && r.Observation == "WouldSend")));
}
