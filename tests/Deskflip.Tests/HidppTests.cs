using System.Text;
using Deskflip.Core;
using Deskflip.Tests.Fakes;
using Xunit;

namespace Deskflip.Tests;

public sealed class HidppTests
{
    private readonly FakeClock clock = new();

    public static TheoryData<byte[], byte[]> Packets() => new()
    {
        { HidppPackets.Feature(HidppFeature.ChangeHost), [0x11, 0xFF, 0, 0x0B, 0x18, 0x14] },
        { HidppPackets.Feature(HidppFeature.HostsInfo), [0x11, 0xFF, 0, 0x0B, 0x18, 0x15] },
        { HidppPackets.State(0xA), [0x11, 0xFF, 0xA, 0x0B] },
        { HidppPackets.ChangeHost(0xA, 3), [0x11, 0xFF, 0xA, 0x1B, 2] },
        { HidppPackets.HostsSummary(0xB), [0x11, 0xFF, 0xB, 0x0B] },
        { HidppPackets.HostInfo(0xB, 2), [0x11, 0xFF, 0xB, 0x1B, 1] },
        { HidppPackets.HostName(0xB, 2, 14), [0x11, 0xFF, 0xB, 0x3B, 1, 14] },
    };

    [Theory]
    [MemberData(nameof(Packets))]
    public void FixedSurfaceUsesLongReportsAndZeroBasedHost(byte[] packet, byte[] prefix)
    {
        Assert.Equal(20, packet.Length);
        Assert.Equal(prefix, packet.Take(prefix.Length));
        Assert.All(packet.Skip(prefix.Length), b => Assert.Equal(0, b));
    }

    [Fact]
    public void RejectsInvalidFeatureIndexChannelAndFeature()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => HidppPackets.State(0));
        Assert.Throws<ArgumentOutOfRangeException>(() => HidppPackets.State(255));
        Assert.Throws<ArgumentOutOfRangeException>(() => HidppPackets.ChangeHost(10, 0));
        Assert.Throws<ArgumentOutOfRangeException>(() => HidppPackets.ChangeHost(10, 4));
        Assert.Throws<ArgumentOutOfRangeException>(() => HidppPackets.Feature((HidppFeature)1));
    }

    [Fact]
    public void MatchingIncludesSoftwareIdDeviceIndexReportLengthAndErrorFrame()
    {
        var request = HidppPackets.State(10);
        Assert.Equal(HidppReply.Match, HidppPackets.Match(request, Reply(request, 3, 0)));
        foreach (var index in new[] { 0, 1, 2, 3 })
        {
            var other = Reply(request, 3, 0);
            other[index] ^= 1;
            Assert.Equal(HidppReply.Unrelated, HidppPackets.Match(request, other));
        }
        Assert.Equal(HidppReply.Unrelated, HidppPackets.Match(request, [0x11]));
        var error = new byte[20];
        new byte[] { 0x11, 0xFF, 0xFF, 10, 0x0B, 2 }.CopyTo(error, 0);
        Assert.Equal(HidppReply.Error, HidppPackets.Match(request, error));
    }

    [Fact]
    public void ResolvesFirmwareIndexesAndReadsUtf8NamesInChunksWithoutChangingHost()
    {
        using var transport = new FakeTransport(clock);
        const string name = "test-long-destination-é";
        var bytes = Encoding.UTF8.GetBytes(name);
        transport.OnWrite = request =>
        {
            var response = request[2] switch
            {
                0 => Reply(request, request[5] == 0x14 ? (byte)8 : (byte)9),
                8 => Reply(request, 3, 0),
                9 when request[3] == 0x0B => Reply(request, 1, 0, 3),
                9 when request[3] == 0x1B => Reply(request, 1, 1, 0, 0, (byte)bytes.Length),
                9 when request[3] == 0x3B => Reply(request, new byte[] { 1, request[5] }
                    .Concat(bytes.Skip(request[5]).Take(14)).ToArray()),
                _ => throw new InvalidOperationException("Unexpected packet"),
            };
            transport.Replies.Enqueue(() => response);
        };
        using var session = new HidppSession(transport, clock);
        Assert.Equal(new HostState(3, 1), session.ReadState());
        Assert.Equal(new HostSlot(2, true, name), session.ReadHost(2));
        Assert.DoesNotContain(transport.Writes, p => p[2] == 8 && p[3] == 0x1B);
        Assert.Equal(2, transport.Writes.Count(p => p[2] == 0));
    }

    [Fact]
    public void DuplicateFeatureReplyCannotTurnHostInfoQueryIntoChangeHost()
    {
        using var transport = new FakeTransport(clock);
        transport.OnWrite = p => transport.Replies.Enqueue(() => p[2] == 0 ? Reply(p, 10) : Reply(p, 3, 0));
        using var session = new HidppSession(transport, clock);
        session.ReadState();
        Assert.Throws<IOException>(() => session.ReadHost(2));
        Assert.DoesNotContain(transport.Writes, p => p[3] == 0x1B);
    }

    [Fact]
    public void IgnoresNotificationsAndUsesOneRetryOnTimeout()
    {
        using var transport = new FakeTransport(clock);
        transport.OnWrite = p =>
        {
            if (transport.Writes.Count == 1) return; // first root lookup times out
            transport.Replies.Enqueue(() => new byte[20]);
            transport.Replies.Enqueue(() => p[2] == 0 ? Reply(p, 10) : Reply(p, 3, 0));
        };
        using var session = new HidppSession(transport, clock);
        Assert.Equal(1, session.ReadState().CurrentChannel);
        Assert.Equal(2, transport.Writes.Count(p => p[2] == 0));
        Assert.All(transport.Budgets, b => Assert.InRange(b.TotalMilliseconds, 1, 500));
    }

    [Fact]
    public void UnendingNotificationsStillReachDeadlineAndStopAfterTwoQueries()
    {
        using var transport = new FakeTransport(clock) { NotificationsForever = true };
        using var session = new HidppSession(transport, clock);
        var start = clock.MonotonicMilliseconds;
        Assert.Throws<TimeoutException>(() => session.ReadState());
        Assert.Equal(2, transport.Writes.Count);
        Assert.InRange(clock.MonotonicMilliseconds - start, 1000, 1020);
    }

    [Theory]
    [InlineData(0, 0)] [InlineData(4, 0)] [InlineData(3, 3)]
    public void InvalidHostStateFailsClosed(byte slots, byte current)
    {
        using var transport = new FakeTransport(clock);
        transport.OnWrite = p => transport.Replies.Enqueue(() => p[2] == 0 ? Reply(p, 10) : Reply(p, slots, current));
        using var session = new HidppSession(transport, clock);
        Assert.Throws<IOException>(() => session.ReadState());
    }

    [Fact]
    public void ErrorReplyFailsImmediatelyWithoutRetry()
    {
        using var transport = new FakeTransport(clock);
        transport.OnWrite = p => transport.Replies.Enqueue(() =>
        {
            var response = new byte[20];
            new byte[] { 0x11, 0xFF, 0xFF, p[2], p[3], 2 }.CopyTo(response, 0);
            return response;
        });
        using var session = new HidppSession(transport, clock);
        Assert.Throws<HidppQueryException>(() => session.ReadState());
        Assert.Equal((byte)2, session.Diagnostics.LastQueryError);
        Assert.Single(transport.Writes);
    }

    [Theory]
    [InlineData(false)] [InlineData(true)]
    public void CapturesChangeHostRejectionDuringPassiveWindowOrLaterQuery(bool late)
    {
        using var transport = new FakeTransport(clock);
        byte[]? change = null;
        transport.OnWrite = p =>
        {
            if (p[3] == 0x1B)
            {
                change = p;
                if (!late) transport.Replies.Enqueue(() => ErrorReply(p, 8));
                return;
            }
            if (late && change is not null) transport.Replies.Enqueue(() => ErrorReply(change, 8));
            transport.Replies.Enqueue(() => p[2] == 0 ? Reply(p, 10, 0, 2) : Reply(p, 3, 1));
        };
        using var session = new HidppSession(transport, clock);
        session.ReadState();
        session.ChangeHost(1);
        Assert.Equal("StillHere", session.ObserveDeparture(TimeSpan.FromSeconds(2)));
        Assert.Equal((byte)8, session.Diagnostics.ChangeHostError);
        Assert.Equal((byte)10, session.Diagnostics.ChangeHostIndex);
        Assert.Equal((byte)2, session.Diagnostics.ChangeHostVersion);
        Assert.Equal(2, session.Diagnostics.LastCurrentChannel);
        Assert.True(session.Diagnostics.StateReplies > 1);
        Assert.Single(transport.Writes, p => p[3] == 0x1B);
    }

    [Fact]
    public void ForeignErrorDoesNotBecomeOurChangeHostRejection()
    {
        using var transport = new FakeTransport(clock);
        transport.OnWrite = p =>
        {
            if (p[3] == 0x1B)
            {
                var foreign = ErrorReply(p, 8);
                foreign[4] ^= 1; // another application's software ID
                transport.Replies.Enqueue(() => foreign);
            }
            else transport.Replies.Enqueue(() => p[2] == 0 ? Reply(p, 10) : Reply(p, 3, 1));
        };
        using var session = new HidppSession(transport, clock);
        session.ReadState();
        session.ChangeHost(1);
        session.ObserveDeparture(TimeSpan.FromSeconds(2));
        Assert.Null(session.Diagnostics.ChangeHostError);
    }

    [Fact]
    public void DepartureStartsWithReadOnlyWindowAndKeepsTotalBudget()
    {
        using var transport = new FakeTransport(clock);
        transport.OnWrite = p => transport.Replies.Enqueue(() => p[2] == 0 ? Reply(p, 10) : Reply(p, 3, 1));
        using var session = new HidppSession(transport, clock);
        session.ReadState();
        transport.OnWrite = _ => { };
        session.ChangeHost(1);
        var start = clock.MonotonicMilliseconds;
        transport.OnWrite = _ => Assert.True(clock.MonotonicMilliseconds - start >= 250);
        Assert.Equal("Unknown", session.ObserveDeparture(TimeSpan.FromSeconds(2)));
        Assert.True(session.Diagnostics.Timeouts > 0);
        Assert.InRange(clock.MonotonicMilliseconds - start, 0, 2000);
        Assert.Single(transport.Writes, p => p[3] == 0x1B);
    }

    [Fact]
    public void KeepsNativeErrorCodeWithoutExceptionText()
    {
        using var transport = new FakeTransport(clock);
        transport.OnWrite = _ => throw new HidppIoException(31);
        using var session = new HidppSession(transport, clock);
        Assert.Throws<HidppIoException>(() => session.ReadState());
        Assert.Equal(31, session.Diagnostics.LastNativeError);
        Assert.Equal(1, session.Diagnostics.IoFailures);
        Assert.Single(transport.Writes);
    }

    private static byte[] ErrorReply(byte[] request, byte code)
    {
        var reply = new byte[20];
        new byte[] { 0x11, 0xFF, 0xFF, request[2], request[3], code }.CopyTo(reply, 0);
        return reply;
    }

    [Theory]
    [InlineData(false)] [InlineData(true)]
    public void ChangeHostCannotBeRetriedEvenWhenWriteThrows(bool throwWrite)
    {
        using var transport = new FakeTransport(clock);
        transport.OnWrite = p =>
        {
            if (p[3] == 0x1B)
            {
                if (throwWrite) throw new TimeoutException();
                return;
            }
            transport.Replies.Enqueue(() => p[2] == 0 ? Reply(p, 10) : Reply(p, 3, 0));
        };
        using var session = new HidppSession(transport, clock);
        session.ReadState();
        if (throwWrite) Assert.Throws<TimeoutException>(() => session.ChangeHost(2));
        else session.ChangeHost(2);
        Assert.Throws<InvalidOperationException>(() => session.ChangeHost(2));
        Assert.Single(transport.Writes, p => p[3] == 0x1B);
    }

    [Theory]
    [InlineData("Left")] [InlineData("StillHere")] [InlineData("Unknown")]
    public void ObservationsDistinguishDisconnectFromSilence(string expected)
    {
        using var transport = new FakeTransport(clock);
        transport.OnWrite = p => transport.Replies.Enqueue(() => p[2] == 0 ? Reply(p, 10) : Reply(p, 3, 0));
        using var session = new HidppSession(transport, clock);
        session.ReadState();
        transport.OnWrite = _ => { };
        session.ChangeHost(2);
        transport.OnWrite = p =>
        {
            if (expected == "Left") throw new FollowerDisconnectedException();
            if (expected == "StillHere") transport.Replies.Enqueue(() => Reply(p, 3, 0));
        };
        var start = clock.MonotonicMilliseconds;
        Assert.Equal(expected, session.ObserveDeparture(TimeSpan.FromSeconds(2)));
        Assert.InRange(clock.MonotonicMilliseconds - start, 0, 2000);
        Assert.Single(transport.Writes, p => p[3] == 0x1B);
    }

    private static byte[] Reply(byte[] request, params byte[] parameters)
    {
        var reply = new byte[20];
        Array.Copy(request, reply, 4);
        parameters.CopyTo(reply, 4);
        return reply;
    }

    private sealed class FakeTransport(FakeClock clock) : IHidppTransport
    {
        public List<byte[]> Writes { get; } = [];
        public List<TimeSpan> Budgets { get; } = [];
        public Queue<Func<byte[]>> Replies { get; } = [];
        public Action<byte[]>? OnWrite { get; set; }
        public bool NotificationsForever { get; set; }
        public void Write(byte[] report, TimeSpan timeout)
        {
            Budgets.Add(timeout);
            Writes.Add(report);
            OnWrite?.Invoke(report);
        }
        public byte[] Read(TimeSpan timeout)
        {
            Budgets.Add(timeout);
            if (Replies.Count > 0) { clock.Delay(TimeSpan.FromMilliseconds(1)); return Replies.Dequeue()(); }
            if (NotificationsForever) { clock.Delay(TimeSpan.FromMilliseconds(Math.Min(10, timeout.TotalMilliseconds))); return new byte[20]; }
            clock.Delay(timeout);
            throw new TimeoutException();
        }
        public void Dispose() { }
    }
}
