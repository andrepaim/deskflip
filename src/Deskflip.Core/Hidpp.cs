using System.Text;

namespace Deskflip.Core;

// Transport is injectable for hardware-free tests. There is no raw-report command or configuration.
public interface IHidppTransport : IDisposable
{
    void Write(byte[] report, TimeSpan timeout);
    byte[] Read(TimeSpan timeout);
}

public enum HidppFeature : ushort { ChangeHost = 0x1814, HostsInfo = 0x1815 }
public enum HidppReply { Unrelated, Match, Error }

public static class HidppPackets
{
    public const byte SoftwareId = 0xB;
    public const int ReportLength = 20;

    public static byte[] Feature(HidppFeature feature)
    {
        if (feature is not (HidppFeature.ChangeHost or HidppFeature.HostsInfo)) throw new ArgumentOutOfRangeException(nameof(feature));
        return Packet(0, 0, (byte)((ushort)feature >> 8), (byte)feature);
    }
    public static byte[] State(byte index) => Packet(FeatureIndex(index), 0);
    public static byte[] ChangeHost(byte index, int channel) => Packet(FeatureIndex(index), 1, Host(channel));
    public static byte[] HostsSummary(byte index) => Packet(FeatureIndex(index), 0);
    public static byte[] HostInfo(byte index, int channel) => Packet(FeatureIndex(index), 1, Host(channel));
    public static byte[] HostName(byte index, int channel, byte offset) => Packet(FeatureIndex(index), 3, Host(channel), offset);

    private static byte Host(int channel) => channel is >= 1 and <= 3 ? (byte)(channel - 1) : throw new ArgumentOutOfRangeException(nameof(channel));
    private static byte FeatureIndex(byte index) => index is > 0 and < 255 ? index : throw new ArgumentOutOfRangeException(nameof(index));
    private static byte[] Packet(byte index, byte function, params byte[] parameters)
    {
        var bytes = new byte[ReportLength];
        bytes[0] = 0x11; bytes[1] = 0xFF; bytes[2] = index; bytes[3] = (byte)((function << 4) | SoftwareId);
        parameters.CopyTo(bytes, 4);
        return bytes;
    }

    public static HidppReply Match(byte[] request, byte[] reply)
    {
        if (request.Length != ReportLength || reply.Length != ReportLength || reply[0] != 0x11 || reply[1] != 0xFF)
            return HidppReply.Unrelated;
        if (reply[2] == 0xFF && reply[3] == request[2] && reply[4] == request[3]) return HidppReply.Error;
        return reply[2] == request[2] && reply[3] == request[3] ? HidppReply.Match : HidppReply.Unrelated;
    }
}

/// <summary>Only design v1.2 §5 queries and the single change-host write. Feature indexes live for one session.</summary>
public sealed class HidppSession(IHidppTransport transport, IClock clock) : IFollowerSession
{
    private byte? changeIndex;
    private byte? hostsIndex;
    private byte? changeVersion;
    private bool changeAttempted;
    private byte[]? changeRequest;
    private int? lastCurrentChannel;
    private int stateReplies, timeouts, ioFailures;
    private int? lastNativeError;
    private byte? lastQueryError, changeHostError;
    private static readonly UTF8Encoding HostEncoding = new(false, true);
    public FollowerDiagnostics Diagnostics => new(changeIndex, changeVersion, hostsIndex, lastCurrentChannel,
        stateReplies, timeouts, ioFailures, lastNativeError, lastQueryError, changeHostError);

    private byte Resolve(HidppFeature feature)
    {
        var reply = Query(HidppPackets.Feature(feature));
        if (reply[4] is 0 or 255) throw new IOException("Required HID++ feature unavailable.");
        if (feature == HidppFeature.ChangeHost) changeVersion = reply[6];
        return reply[4];
    }

    public HostState ReadState()
    {
        changeIndex ??= Resolve(HidppFeature.ChangeHost);
        return DecodeState(Query(HidppPackets.State(changeIndex.Value)));
    }

    private HostState DecodeState(byte[] reply)
    {
        if (reply[4] is < 1 or > 3 || reply[5] >= reply[4]) throw new IOException("Invalid HID++ host state.");
        lastCurrentChannel = reply[5] + 1;
        stateReplies++;
        return new(reply[4], lastCurrentChannel.Value);
    }

    public HostSlot ReadHost(int channel)
    {
        // A late duplicate root reply must never make the hosts-info function 1 become change-host.
        changeIndex ??= Resolve(HidppFeature.ChangeHost);
        hostsIndex ??= Resolve(HidppFeature.HostsInfo);
        if (hostsIndex == changeIndex) throw new IOException("HID++ feature indexes are ambiguous.");
        var index = hostsIndex.Value;
        var summary = Query(HidppPackets.HostsSummary(index));
        if (summary[6] is < 1 or > 3 || channel < 1 || channel > summary[6]) throw new IOException("Invalid HID++ host count.");
        var slot = Query(HidppPackets.HostInfo(index, channel), r => r[4] == channel - 1);
        if (slot[5] == 0) return new(channel, false, null);
        if ((summary[4] & 1) == 0) return new(channel, true, null);
        var name = new byte[slot[8]];
        for (var offset = 0; offset < name.Length; offset += 14)
        {
            var part = Query(HidppPackets.HostName(index, channel, (byte)offset), r => r[4] == channel - 1 && r[5] == offset);
            Array.Copy(part, 6, name, offset, Math.Min(14, name.Length - offset));
        }
        return new(channel, true, HostEncoding.GetString(name));
    }

    public void ChangeHost(int channel)
    {
        if (changeAttempted) throw new InvalidOperationException("Change host was already attempted on this session.");
        if (changeIndex is null) throw new InvalidOperationException("Preflight is required before change host.");
        var packet = HidppPackets.ChangeHost(changeIndex.Value, channel);
        changeAttempted = true;
        changeRequest = packet;
        try { transport.Write(packet, TimeSpan.FromMilliseconds(500)); }
        catch (Exception error) when (error is IOException or TimeoutException) { RecordError(error); throw; }
        // No success acknowledgement exists. ObserveDeparture can capture a rejection, never resend.
    }

    public string ObserveDeparture(TimeSpan budget)
    {
        if (!changeAttempted || changeIndex is null) return "Unknown";
        var deadline = clock.MonotonicMilliseconds + Math.Clamp((long)budget.TotalMilliseconds, 0, 2000);
        var observation = "Unknown";
        // Give the no-reply command a bounded passive window before sending any state query.
        // A rejection frame here used to be discarded as unrelated to the subsequent state request.
        var passiveDeadline = Math.Min(deadline, clock.MonotonicMilliseconds + 250);
        while (clock.MonotonicMilliseconds < passiveDeadline)
        {
            try { CaptureChangeError(transport.Read(TimeSpan.FromMilliseconds(passiveDeadline - clock.MonotonicMilliseconds))); }
            catch (FollowerDisconnectedException) { return "Left"; }
            catch (Exception error) when (error is IOException or TimeoutException) { RecordError(error); break; }
        }
        while (clock.MonotonicMilliseconds < deadline)
        {
            try
            {
                DecodeState(QueryOnce(HidppPackets.State(changeIndex.Value), null,
                    (int)Math.Min(500, deadline - clock.MonotonicMilliseconds)));
                observation = "StillHere";
            }
            catch (FollowerDisconnectedException) { return "Left"; }
            catch (Exception error) when (error is IOException or TimeoutException) { observation = "Unknown"; }
            var remaining = deadline - clock.MonotonicMilliseconds;
            if (remaining > 0) clock.Delay(TimeSpan.FromMilliseconds(Math.Min(100, remaining)));
        }
        return observation;
    }

    private byte[] Query(byte[] request, Func<byte[], bool>? additionalMatch = null)
    {
        try { return QueryOnce(request, additionalMatch, 500); }
        catch (TimeoutException) { return QueryOnce(request, additionalMatch, 500); }
    }

    private byte[] QueryOnce(byte[] request, Func<byte[], bool>? additionalMatch, int timeoutMs)
    {
        try { return Exchange(request, additionalMatch, timeoutMs); }
        catch (Exception error) when (error is IOException or TimeoutException) { RecordError(error); throw; }
    }

    private byte[] Exchange(byte[] request, Func<byte[], bool>? additionalMatch, int timeoutMs)
    {
        if (timeoutMs <= 0) throw new TimeoutException();
        var deadline = clock.MonotonicMilliseconds + timeoutMs;
        transport.Write(request, TimeSpan.FromMilliseconds(timeoutMs));
        while (clock.MonotonicMilliseconds < deadline)
        {
            var reply = transport.Read(TimeSpan.FromMilliseconds(deadline - clock.MonotonicMilliseconds));
            var match = HidppPackets.Match(request, reply);
            CaptureChangeError(reply);
            if (match == HidppReply.Error) throw new HidppQueryException(reply[5]);
            if (match == HidppReply.Match && (additionalMatch is null || additionalMatch(reply))) return reply;
        }
        throw new TimeoutException("HID++ query timed out.");
    }

    public void Dispose() => transport.Dispose();

    private void CaptureChangeError(byte[] reply)
    {
        if (changeRequest is not null && HidppPackets.Match(changeRequest, reply) == HidppReply.Error)
            changeHostError = reply[5];
    }

    private void RecordError(Exception error)
    {
        switch (error)
        {
            case TimeoutException: timeouts++; break;
            case HidppQueryException query: lastQueryError = query.ErrorCode; break;
            case HidppIoException io: ioFailures++; lastNativeError = io.NativeError; break;
            case FollowerDisconnectedException: break;
            case IOException: ioFailures++; break;
        }
    }
}
