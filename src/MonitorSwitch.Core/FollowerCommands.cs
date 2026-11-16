namespace MonitorSwitch.Core;

public sealed class FollowerCommands(IFollowerLocator locator, IOperationStore store, IOperationLock operationLock,
    IConfigStore configStore, IClock clock)
{
    // Callback runs before releasing the shared lock, including enrollment's derived report.
    public CommandReport Run(Command command, Action<CommandReport>? report = null)
    {
        using var lease = operationLock.TryAcquire();
        if (lease is null) return new(Outcomes.Busy, ExitCodes.BusyOrDebounced);
        var result = command.Kind switch
        {
            CommandKind.Followers => Inventory(),
            CommandKind.EnrollFollower => Enroll(command),
            _ => throw new ArgumentException("Not a follower maintenance command."),
        };
        report?.Invoke(result);
        return result;
    }

    public SwitchResult Follow(Command command, IResultReporter reporter)
    {
        var start = clock.MonotonicMilliseconds;
        var result = new SwitchResult(Guid.NewGuid().ToString("N"), "follow", Outcomes.Busy, null, null, null, ExitCodes.BusyOrDebounced);
        using var lease = operationLock.TryAcquire();
        if (lease is not null)
        {
            var config = LoadConfig() ?? throw new ConfigurationException("Not enrolled.");
            var follow = config.Follow ?? throw new ConfigurationException("No followers enrolled.");
            var state = store.Read();
            if (state is not null && state.EnrolledIdentity != config.Identity)
                throw new ConfigurationException("State belongs to a different monitor enrollment.");
            if (state?.Pending is not null)
                result = result with { Outcome = Outcomes.OutcomeUnverified, ExitCode = ExitCodes.OutcomeUnverified,
                    Detail = "Pending monitor operation retained; reconcile it before following." };
            else if (state?.LastCompletion is { } stamp && stamp.BootIdentity == clock.BootIdentity
                && clock.MonotonicMilliseconds - stamp.MonotonicMilliseconds is var elapsed
                && elapsed >= 0 && elapsed < config.Operation.CooldownMs)
                result = result with { Outcome = Outcomes.Debounced };
            else
            {
                if (command.FollowerName is { } name)
                {
                    var selected = follow.Devices.Where(d => d.Name == name).ToArray();
                    if (selected.Length != 1) throw new ConfigurationException("Unknown enrolled follower name.");
                    follow = follow with { Devices = selected };
                }
                var observations = new FollowerCoordinator(locator).Run(follow, false);
                var success = FollowerCoordinator.Succeeded(observations);
                result = result with { Followers = observations, Outcome = success ? "Followed" : Outcomes.FollowIncomplete,
                    ExitCode = success ? ExitCodes.Success : ExitCodes.FollowIncomplete };
            }
        }
        result = result with { ElapsedMs = clock.MonotonicMilliseconds - start };
        try { reporter.Report(result); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        return result;
    }

    private CommandReport Inventory()
    {
        var config = LoadConfig();
        var entries = new List<object>();
        var discovered = locator.Discover();
        foreach (var identity in discovered.Distinct())
        {
            HostState? state = null;
            FollowerDiagnostics? diagnostics = null;
            var slots = new List<HostSlot>();
            string? problem = null;
            try
            {
                using var session = locator.OpenUnique(identity);
                state = session.ReadState();
                for (var channel = 1; channel <= state.SlotCount; channel++) slots.Add(session.ReadHost(channel));
                diagnostics = session.Diagnostics;
            }
            catch (Exception error) when (error is not OutOfMemoryException) { problem = "Missing, ambiguous, unsupported or unreachable."; }
            entries.Add(new { identity, state, slots, diagnostics, problem,
                enrolledName = config?.Follow?.Devices.FirstOrDefault(d => Matches(d, identity))?.Name });
        }
        foreach (var d in config?.Follow?.Devices ?? [])
            if (!discovered.Any(i => Matches(d, i))) entries.Add(new { enrolledName = d.Name, problem = "Enrolled follower absent." });
        return new("FollowersDiscovered", ExitCodes.Success, new { followers = entries });
    }

    private CommandReport Enroll(Command command)
    {
        var config = LoadConfig() ?? throw new ConfigurationException("Enroll the monitor first.");
        var state = store.Read();
        if (state?.Pending is not null) return Refuse("Pending monitor operation retained; reconcile before changing enrollment.");
        if (state is not null && state.EnrolledIdentity != config.Identity) return Refuse("Monitor state and enrollment differ.");
        var name = command.FollowerName!;
        if (!FollowerValidation.IsName(name)) return Refuse("Follower name must contain 1-64 ASCII letters, digits, hyphens or underscores.");
        var devices = (config.Follow?.Devices ?? []).ToList();
        var existing = devices.FindIndex(d => d.Name.Equals(name, StringComparison.OrdinalIgnoreCase));
        if (command.RemoveFollower)
        {
            if (existing < 0) return Refuse("Follower is not enrolled.");
            devices.RemoveAt(existing);
        }
        else
        {
            if (existing >= 0 && !command.ReplaceEnrollment) return Refuse("Follower exists; replacement requires --replace.");
            var matches = locator.Discover().Where(d => d.ProductId.Equals(command.ProductId, StringComparison.OrdinalIgnoreCase)).ToArray();
            if (matches.Length != 1) return Refuse("Exactly one device with the requested product ID must be present.");
            using var session = locator.OpenUnique(matches[0]);
            var current = session.ReadState();
            var channel = command.Channel!.Value;
            if (channel > current.SlotCount) return Refuse("Channel does not exist on this device.");
            var slot = session.ReadHost(channel);
            if (slot.Channel != channel || !slot.Paired || !FollowerValidation.IsHostName(slot.HostName))
                return Refuse("Target channel must be paired and report a usable host name.");
            var enrolled = new FollowerConfig(name, matches[0].ProductId, matches[0].DevicePathHash, channel, slot.HostName!);
            if (existing >= 0) devices[existing] = enrolled;
            else devices.Add(enrolled);
        }
        var next = config with { Follow = devices.Count == 0 ? null : new(config.Follow?.AwayInput ?? 6, devices.ToArray()) };
        ConfigParser.Validate(next);
        configStore.ReplaceAtomically(next);
        return new(command.RemoveFollower ? "FollowerRemoved" : "FollowerEnrolled", ExitCodes.Success,
            new { name, replacedPrevious = existing >= 0 && !command.RemoveFollower });
    }

    private static bool Matches(FollowerConfig device, FollowerIdentity identity) =>
        device.ProductId.Equals(identity.ProductId, StringComparison.OrdinalIgnoreCase) && device.DevicePathHash == identity.DevicePathHash;
    private AppConfig? LoadConfig() => configStore.ReadText() is { } text ? ConfigParser.Parse(text) : null;
    private static CommandReport Refuse(string reason) => new(Outcomes.InvalidConfiguration, ExitCodes.InvalidConfiguration, new { error = reason });
}
