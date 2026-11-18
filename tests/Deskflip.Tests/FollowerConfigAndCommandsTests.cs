using System.Text.Json;
using System.Text.Json.Nodes;
using Deskflip.Core;
using Deskflip.Runtime;
using Deskflip.Tests.Fakes;
using Xunit;

namespace Deskflip.Tests;

public sealed class FollowerConfigTests
{
    [Fact]
    public void MissingFollowRemainsValidAndEnrollmentKeepsFollowers()
    {
        var json = JsonSerializer.Serialize(TestData.Config(), StrictJson.Options);
        var node = JsonNode.Parse(json)!.AsObject();
        node.Remove("follow");
        Assert.Null(ConfigParser.Parse(node.ToJsonString()).Follow);
        var config = ConfigParser.Parse(JsonSerializer.Serialize(FollowerData.Config, StrictJson.Options));
        Assert.Equal(2, config.Follow!.Devices.Length);
        Assert.Equal(config.Follow, ConfigParser.ForEnrollment(TestData.Candidate(), config).Follow);
    }

    public static TheoryData<string> Invalid()
    {
        string Mutate(Action<JsonNode> edit)
        {
            var node = JsonNode.Parse(JsonSerializer.Serialize(FollowerData.Config, StrictJson.Options))!;
            edit(node["follow"]!);
            return node.ToJsonString();
        }
        return new()
        {
            Mutate(f => f["awayInput"] = 17),
            Mutate(f => f["extra"] = true),
            Mutate(f => f["devices"] = new JsonArray()),
            Mutate(f => f["devices"] = null),
            Mutate(f => f["devices"]![0] = null),
            Mutate(f => f["devices"]![0]!["name"] = "<name>"),
            Mutate(f => f["devices"]![0]!["name"] = "keyboard"),
            Mutate(f => f["devices"]![0]!["productId"] = "B03G"),
            Mutate(f => f["devices"]![0]!["productId"] = "031"),
            Mutate(f => f["devices"]![0]!["devicePathHash"] = new string('A', 64)),
            Mutate(f => f["devices"]![0]!["awayChannel"] = 0),
            Mutate(f => f["devices"]![0]!["awayChannel"] = 4),
            Mutate(f => f["devices"]![0]!["awayChannel"] = "2"),
            Mutate(f => f["devices"]![0]!["awayHostName"] = "<captured>"),
            Mutate(f => f["devices"]![0]!["awayHostName"] = ""),
            Mutate(f => f["devices"]![0]!["awayHostName"] = null),
            Mutate(f => f["devices"]![0]!["arbitraryReport"] = "11ff"),
            Mutate(f => f["devices"]![0]!.AsObject().Remove("devicePathHash")),
            Mutate(f => { f["devices"]![0]!["productId"] = "B359"; f["devices"]![0]!["devicePathHash"] = FollowerData.Keyboard.DevicePathHash; }),
        };
    }

    [Theory]
    [MemberData(nameof(Invalid))]
    public void InvalidFollowerConfigIsRejected(string json) => Assert.Throws<ConfigurationException>(() => ConfigParser.Parse(json));

    [Fact]
    public void ConfigReplacementKeepsExactPreviousEnrollmentBackup()
    {
        var directory = Path.Combine(Path.GetTempPath(), "Deskflip-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var path = Path.Combine(directory, "config.json");
            var backup = Path.Combine(directory, "config.previous.json");
            var files = new FileConfigStore(path, backup);
            files.ReplaceAtomically(TestData.Config());
            var previous = File.ReadAllText(path);
            files.ReplaceAtomically(FollowerData.Config);
            Assert.Equal(previous, File.ReadAllText(backup));
            Assert.Equal(2, ConfigParser.Parse(File.ReadAllText(path)).Follow!.Devices.Length);
        }
        finally { Directory.Delete(directory, true); }
    }
}

public sealed class FollowerCommandLineTests
{
    [Fact]
    public void ParsesOnlyDocumentedFollowerCommands()
    {
        Assert.True(CommandLine.Parse(["toggle", "--no-follow"]).NoFollow);
        Assert.True(CommandLine.Parse(["toggle", "--dry-run", "--no-follow"]).DryRun);
        Assert.Equal(CommandKind.Followers, CommandLine.Parse(["followers", "--output", "inventory.json"]).Kind);
        Assert.Equal("mouse", CommandLine.Parse(["follow", "--device", "mouse"]).FollowerName);
        var enroll = CommandLine.Parse(["enroll-follower", "--name", "keyboard", "--product-id", "b359", "--channel", "2", "--replace"]);
        Assert.Equal(("B359", 2, true), (enroll.ProductId, enroll.Channel, enroll.ReplaceEnrollment));
        Assert.True(CommandLine.Parse(["enroll-follower", "--name", "keyboard", "--remove"]).RemoveFollower);
    }

    [Theory]
    [InlineData("followers")]
    [InlineData("set --input 6 --no-follow")]
    [InlineData("follow --dry-run")]
    [InlineData("follow --raw 11ff")]
    [InlineData("enroll-follower --name keyboard --remove --replace")]
    [InlineData("enroll-follower --name keyboard --remove --channel 2")]
    [InlineData("enroll-follower --name keyboard --product-id B359 --channel 0")]
    [InlineData("enroll-follower --name keyboard --product-id B359 --channel 04")]
    [InlineData("enroll-follower --name keyboard --product-id B359")]
    [InlineData("enroll-follower --name keyboard --channel 2")]
    public void RejectsUnsupportedOrIncompleteCommands(string command) =>
        Assert.Throws<ArgumentException>(() => CommandLine.Parse(command.Split(' ')));
}

public sealed class FollowerCommandsTests
{
    private readonly FakeFollowerLocator locator = new();
    private readonly FakeConfigStore config = new() { Text = JsonSerializer.Serialize(TestData.Config(), StrictJson.Options) };
    private readonly FakeStore state = new();
    private readonly FakeLock operationLock = new();
    private readonly FakeClock clock = new();
    private FollowerCommands Commands => new(locator, state, operationLock, config, clock);
    private static Command Enroll => CommandLine.Parse(["enroll-follower", "--name", "keyboard", "--product-id", "B359", "--channel", "2"]);

    [Fact]
    public void EnrollmentCapturesIdentityAndHostNameWithNoDeviceOrStateWrites()
    {
        var keyboard = locator.Add(FollowerData.Keyboard);
        Assert.Equal(0, Commands.Run(Enroll, _ => Assert.True(operationLock.Held)).ExitCode);
        Assert.Equal(FollowerData.Keyboard, config.Saved.Single().Follow!.Devices.Single());
        Assert.Empty(keyboard.Sends);
        Assert.Empty(state.Saved);
        Assert.Equal(10, Commands.Run(Enroll).ExitCode);
        Assert.Equal(0, Commands.Run(Enroll with { ReplaceEnrollment = true }).ExitCode);
        Assert.Equal(0, Commands.Run(new(CommandKind.EnrollFollower, FollowerName: "keyboard", RemoveFollower: true)).ExitCode);
        Assert.Null(config.Saved.Last().Follow);
        Assert.DoesNotContain("\"follow\"", config.Text);
    }

    [Theory]
    [InlineData("ambiguous")] [InlineData("unpaired")] [InlineData("no-name")] [InlineData("pending")]
    public void FailedEnrollmentPreservesConfigAndState(string failure)
    {
        var keyboard = locator.Add(FollowerData.Keyboard);
        switch (failure)
        {
            case "ambiguous": locator.Add(FollowerData.Keyboard with { DevicePathHash = new string('d', 64) }); break;
            case "unpaired": keyboard.Slot = keyboard.Slot with { Paired = false }; break;
            case "no-name": keyboard.Slot = keyboard.Slot with { HostName = null }; break;
            case "pending": state.State = new(1, TestData.Identity, new("pending", TestData.Identity, "toggle", 5, 6, clock.UtcNow), null, null); break;
        }
        Assert.Equal(10, Commands.Run(Enroll).ExitCode);
        Assert.Empty(config.Saved);
        Assert.Empty(state.Saved);
        Assert.Empty(keyboard.Sends);
    }

    [Fact]
    public void InventoryOnlyQueriesAndReportsMissingEnrolledDevice()
    {
        config.Text = JsonSerializer.Serialize(FollowerData.Config, StrictJson.Options);
        var keyboard = locator.Add(FollowerData.Keyboard);
        var result = Commands.Run(new(CommandKind.Followers));
        var json = JsonSerializer.Serialize(result, StrictJson.Output);
        Assert.Contains(FollowerData.Keyboard.AwayHostName, json); // Explicit inventory report may contain host names.
        Assert.Contains("Enrolled follower absent", json);
        Assert.Empty(keyboard.Sends);
        Assert.Empty(state.Saved);
    }

    [Fact]
    public void FollowSelectedDeviceNeverTouchesMonitorStateAndReportsUnderLock()
    {
        config.Text = JsonSerializer.Serialize(FollowerData.Config, StrictJson.Options);
        var keyboard = locator.Add(FollowerData.Keyboard);
        var mouse = locator.Add(FollowerData.Mouse);
        var reporter = new FakeReporter(operationLock);
        var result = Commands.Follow(new(CommandKind.Follow, FollowerName: "keyboard"), reporter);
        Assert.Equal(0, result.ExitCode);
        Assert.Single(keyboard.Sends);
        Assert.Empty(mouse.Sends);
        Assert.Empty(state.Saved);
        Assert.False(reporter.ReportedWhileUnlocked);
        Assert.DoesNotContain(FollowerData.Keyboard.AwayHostName, JsonSerializer.Serialize(result));
    }

    [Fact]
    public void BusyAndPendingBlockStandaloneFollow()
    {
        config.Text = JsonSerializer.Serialize(FollowerData.Config, StrictJson.Options);
        operationLock.Busy = true;
        Assert.Equal(2, Commands.Follow(new(CommandKind.Follow), new FakeReporter()).ExitCode);
        operationLock.Busy = false;
        state.State = new(1, TestData.Identity, new("pending", TestData.Identity, "toggle", 5, 6, clock.UtcNow), null, null);
        Assert.Equal(15, Commands.Follow(new(CommandKind.Follow), new FakeReporter()).ExitCode);
        Assert.Equal(0, locator.OpenCalls);
        Assert.Empty(state.Saved);
    }
}
