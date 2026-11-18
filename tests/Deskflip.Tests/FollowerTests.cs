using System.Text.Json;
using Deskflip.Core;
using Deskflip.Tests.Fakes;
using Xunit;

namespace Deskflip.Tests;

public sealed class FollowerTests
{
    private readonly FakeFollowerLocator locator = new();
    private readonly FakeFollower keyboard;
    private readonly FakeFollower mouse;
    public FollowerTests()
    {
        keyboard = locator.Add(FollowerData.Keyboard);
        mouse = locator.Add(FollowerData.Mouse);
    }
    private IReadOnlyList<FollowerResult> Run(bool dryRun = false) => new FollowerCoordinator(locator).Run(FollowerData.Follow, dryRun);

    [Fact]
    public void AllPreflightBeforeKeyboardThenMouseAndDisposeAll()
    {
        keyboard.OnSend = () =>
        {
            Assert.Equal(1, mouse.HostCalls);
            Assert.Equal(1, keyboard.HostCalls);
            locator.SendOrder.Add("keyboard");
        };
        var results = Run();
        Assert.True(FollowerCoordinator.Succeeded(results));
        Assert.Equal(["keyboard", "mouse"], locator.SendOrder);
        Assert.Equal([2], keyboard.Sends);
        Assert.Equal([3], mouse.Sends);
        Assert.All(results, r => Assert.True(r.CommandSent));
        Assert.Equal((1, 1), (keyboard.DisposeCount, mouse.DisposeCount));
    }

    [Theory]
    [InlineData("missing", false)] [InlineData("missing", true)]
    [InlineData("ambiguous", false)] [InlineData("ambiguous", true)]
    [InlineData("unreachable", false)] [InlineData("unreachable", true)]
    [InlineData("unpaired", false)] [InlineData("unpaired", true)]
    [InlineData("host", false)] [InlineData("host", true)]
    [InlineData("slots", false)] [InlineData("slots", true)]
    [InlineData("current", false)] [InlineData("current", true)]
    public void AnyFailedPreflightBlocksEverySend(string problem, bool failMouse)
    {
        var device = failMouse ? mouse : keyboard;
        var config = failMouse ? FollowerData.Mouse : FollowerData.Keyboard;
        var identity = new FollowerIdentity(config.ProductId, config.DevicePathHash);
        switch (problem)
        {
            case "missing": locator.Devices.Remove(identity); break;
            case "ambiguous": locator.Devices.Add(identity); break;
            case "unreachable": device.ThrowRead = true; break;
            case "unpaired": device.Slot = device.Slot with { Paired = false }; break;
            case "host": device.Slot = device.Slot with { HostName = "different-pairing" }; break;
            case "slots": device.State = new(1, 1); break;
            case "current": device.State = new(3, 0); break;
        }
        var result = Run();
        Assert.False(FollowerCoordinator.Succeeded(result));
        Assert.Empty(keyboard.Sends);
        Assert.Empty(mouse.Sends);
        Assert.DoesNotContain("private path", JsonSerializer.Serialize(result));
    }

    [Fact]
    public void DryRunQueriesButDoesNotSend()
    {
        var result = Run(true);
        Assert.True(FollowerCoordinator.Succeeded(result, true));
        Assert.Empty(keyboard.Sends);
        Assert.Empty(mouse.Sends);
        Assert.All(result, r => Assert.Equal("WouldSend", r.Observation));
    }

    [Fact]
    public void AlreadyThereSkipsHostQueryAndSend()
    {
        keyboard.State = new(3, 2);
        var result = Run();
        Assert.True(FollowerCoordinator.Succeeded(result));
        Assert.Empty(keyboard.Sends);
        Assert.Equal(0, keyboard.HostCalls);
        Assert.Equal("AlreadyThere", result[0].Observation);
    }

    [Theory]
    [InlineData("StillHere")] [InlineData("Unknown")] [InlineData("unexpected")]
    public void UncertainObservationIsIncomplete(string observation)
    {
        mouse.Observation = observation;
        Assert.False(FollowerCoordinator.Succeeded(Run()));
        Assert.Single(mouse.Sends);
        Assert.Single(keyboard.Sends);
    }

    [Fact]
    public void ThrowingSendIsAttemptedOnceAndOtherDeviceStillSent()
    {
        keyboard.ThrowSend = true;
        keyboard.ThrowObserve = true;
        keyboard.ThrowDispose = true;
        var result = Run();
        Assert.False(FollowerCoordinator.Succeeded(result));
        Assert.True(result[0].CommandSent);
        Assert.Equal("Unverified", result[0].SendResult);
        Assert.Equal("Unknown", result[0].Observation);
        Assert.Equal([2], keyboard.Sends);
        Assert.Equal([3], mouse.Sends);
        Assert.Equal(1, mouse.DisposeCount);
    }

    [Fact]
    public void DeviceRejectionOverridesTransportAcceptanceAndCannotReportSuccess()
    {
        keyboard.Diagnostics = new(8, 0, 9, 2, 1, 0, 0, null, null, 8);
        var result = Run();
        Assert.Equal("Rejected", result[0].SendResult);
        Assert.False(FollowerCoordinator.Succeeded(result));
        Assert.Single(keyboard.Sends);
        Assert.Equal((byte)8, result[0].Diagnostics!.ChangeHostError);
    }
}

public sealed class FollowSwitchTests
{
    private readonly FakeLocator monitors = new();
    private readonly FakeStore store = new();
    private readonly FakeLock operationLock = new();
    private readonly FakeClock clock = new();
    private readonly FakeFollowerLocator devices = new();
    private readonly FakeFollower keyboard;
    private readonly FakeFollower mouse;
    public FollowSwitchTests()
    {
        keyboard = devices.Add(FollowerData.Keyboard);
        mouse = devices.Add(FollowerData.Mouse);
    }
    private SwitchResult Run(Command command, AppConfig? config = null) =>
        new SwitchOrchestrator(monitors, store, operationLock, clock, new FakeReporter(operationLock),
            config ?? FollowerData.Config, new FollowerCoordinator(devices)).Run(command);

    [Fact]
    public void FollowOccursAfterDurableConfirmationWithLockHeldAndNeverEntersState()
    {
        monitors.Returns(new(5, 6));
        keyboard.OnSend = () =>
        {
            Assert.True(operationLock.Held);
            Assert.Null(store.State!.Pending);
            Assert.Equal(Outcomes.Confirmed, store.State.LastCompleted!.Outcome);
            Assert.Null(store.State.LastCompleted.Followers);
        };
        var result = Run(new(CommandKind.Toggle));
        Assert.Equal(0, result.ExitCode);
        Assert.NotNull(result.Followers);
        Assert.Equal(2, store.Saved.Count);
        Assert.DoesNotContain("followers", JsonSerializer.Serialize(store.State, StrictJson.Options));
    }

    [Theory]
    [InlineData("set")] [InlineData("no-follow")] [InlineData("home")]
    [InlineData("busy")] [InlineData("debounced")] [InlineData("pending")]
    [InlineData("pending-dry-run")] [InlineData("not-changed")] [InlineData("unverified")]
    [InlineData("save-failed")] [InlineData("old-config")]
    public void ExcludedPathsNeverOpenFollowers(string scenario)
    {
        var command = new Command(CommandKind.Toggle);
        var config = FollowerData.Config;
        uint?[] reads = [5, 6];
        switch (scenario)
        {
            case "set": command = new(CommandKind.Set, 6); break;
            case "no-follow": command = command with { NoFollow = true }; break;
            case "home": reads = [6, 5]; break;
            case "busy": operationLock.Busy = true; break;
            case "debounced": store.State = new(1, TestData.Identity, null, null, new(clock.BootIdentity, clock.MonotonicMilliseconds)); break;
            case "pending": case "pending-dry-run":
                store.State = new(1, TestData.Identity, new("pending", TestData.Identity, "toggle", 5, 6, clock.UtcNow), null, null);
                reads = [6];
                command = command with { DryRun = scenario == "pending-dry-run" };
                break;
            case "not-changed": reads = [5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5]; break;
            case "unverified": reads = [5, null]; break;
            case "save-failed": store.FailOnSave = 2; break;
            case "old-config": config = TestData.Config(); break;
        }
        monitors.Returns(new(reads));
        Run(command, config);
        Assert.Equal(0, devices.OpenCalls);
        Assert.Empty(keyboard.Sends);
        Assert.Empty(mouse.Sends);
    }

    [Fact]
    public void DryRunPlansFollowersWithoutWritingAnything()
    {
        var monitor = new FakeMonitorSession(5);
        monitors.Returns(monitor);
        var result = Run(new(CommandKind.Toggle, DryRun: true));
        Assert.Equal(0, result.ExitCode);
        Assert.All(result.Followers!, r => Assert.Equal("WouldSend", r.Observation));
        Assert.Empty(store.Saved);
        Assert.Empty(monitor.Writes);
        Assert.Empty(keyboard.Sends);
        Assert.Empty(mouse.Sends);
    }

    [Fact]
    public void FailedFollowLeavesMonitorCompletionIntact()
    {
        monitors.Returns(new(5, 6));
        mouse.ThrowRead = true;
        var result = Run(new(CommandKind.Toggle));
        Assert.Equal((Outcomes.FollowIncomplete, 17), (result.Outcome, result.ExitCode));
        Assert.Equal(Outcomes.Confirmed, store.State!.LastCompleted!.Outcome);
        Assert.Equal(0, store.State.LastCompleted.ExitCode);
        Assert.Null(store.State.Pending);
        Assert.Empty(keyboard.Sends);
    }
}
