using MonitorSwitch.Core;

namespace MonitorSwitch.Tests.Fakes;

internal static class FollowerData
{
    public static readonly FollowerConfig Keyboard = new("keyboard", "B359", new string('b', 64), 2, "test-keyboard-destination");
    public static readonly FollowerConfig Mouse = new("mouse", "B031", new string('c', 64), 3, "test-mouse-destination");
    public static FollowConfig Follow => new(6, [Mouse, Keyboard]); // Deliberately reversed to test send ordering.
    public static AppConfig Config => TestData.Config() with { Follow = Follow };
}

internal sealed class FakeFollower : IFollowerSession
{
    public FollowerDiagnostics? Diagnostics { get; set; }
    public HostState State { get; set; } = new(3, 1);
    public HostSlot Slot { get; set; }
    public bool ThrowRead { get; set; }
    public bool ThrowSend { get; set; }
    public bool ThrowObserve { get; set; }
    public bool ThrowDispose { get; set; }
    public string Observation { get; set; } = "Left";
    public int ReadCalls { get; private set; }
    public int HostCalls { get; private set; }
    public int DisposeCount { get; private set; }
    public List<int> Sends { get; } = [];
    public Action? OnSend { get; set; }
    public FakeFollower(FollowerConfig config) => Slot = new(config.AwayChannel, true, config.AwayHostName);
    public HostState ReadState()
    {
        ReadCalls++;
        if (ThrowRead) throw new IOException("private path must not appear in output");
        return State;
    }
    public HostSlot ReadHost(int channel) { HostCalls++; return Slot; }
    public void ChangeHost(int channel)
    {
        Sends.Add(channel);
        OnSend?.Invoke();
        if (ThrowSend) throw new IOException("uncertain send");
    }
    public string ObserveDeparture(TimeSpan budget)
    {
        if (budget > TimeSpan.FromSeconds(2)) throw new InvalidOperationException("Over deadline");
        if (ThrowObserve) throw new IOException("observation failed");
        return Observation;
    }
    public void Dispose() { DisposeCount++; if (ThrowDispose) throw new IOException("dispose failed"); }
}

internal sealed class FakeFollowerLocator : IFollowerLocator
{
    public List<FollowerIdentity> Devices { get; } = [];
    public Dictionary<FollowerIdentity, FakeFollower> Sessions { get; } = [];
    public List<string> SendOrder { get; } = [];
    public int OpenCalls { get; private set; }
    public bool ThrowDiscover { get; set; }
    public FakeFollower Add(FollowerConfig config)
    {
        var id = new FollowerIdentity(config.ProductId, config.DevicePathHash);
        Devices.Add(id);
        var session = new FakeFollower(config) { OnSend = () => SendOrder.Add(config.Name) };
        Sessions.Add(id, session);
        return session;
    }
    public IReadOnlyList<FollowerIdentity> Discover() => ThrowDiscover ? throw new IOException("discovery failed") : Devices;
    public IFollowerSession OpenUnique(FollowerIdentity identity)
    {
        OpenCalls++;
        if (Devices.Count(d => d == identity) != 1) throw new TargetUnavailableException("missing or ambiguous");
        return Sessions[identity];
    }
}
