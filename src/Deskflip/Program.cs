using System.Text.Json;
using Deskflip.Core;
using Deskflip.Runtime;
using Deskflip.Windows;

namespace Deskflip;

internal static class Program
{
    private static int Main(string[] args)
    {
        Command command;
        try { command = CommandLine.Parse(args); }
        catch (ArgumentException) { return ExitCodes.InvalidConfiguration; }
        if (command.Kind == CommandKind.ProbeTrigger) return ProbeRecorder.Record();

        try { return Execute(command); }
        catch (ConfigurationException) { return ExitCodes.InvalidConfiguration; }
        // Boundary: never a stack-trace dialog; the structured exit code is the result.
        catch (Exception) { return ExitCodes.InternalError; }
    }

    private static int Execute(Command command)
    {
        var clock = new SystemClock();
        var locator = new WindowsMonitorLocator();
        var store = new JsonStateStore(AppPaths.State);
        var operationLock = new FileOperationLock(AppPaths.Lock);
        var configStore = new FileConfigStore(AppPaths.Config, AppPaths.ConfigBackup);
        var followerLocator = new WindowsFollowerLocator(clock);
        var followerCommands = new FollowerCommands(followerLocator, store, operationLock, configStore, clock);

        if (command.Kind is CommandKind.Toggle or CommandKind.Set or CommandKind.Follow)
        {
            var config = ConfigParser.Parse(configStore.ReadText() ?? throw new ConfigurationException("Not enrolled."));
            var reporter = new FileResultReporter(AppPaths.Logs, AppPaths.LastResult, clock, config.Monitor.EdidIdentityHash);
            var result = command.Kind == CommandKind.Follow ? followerCommands.Follow(command, reporter)
                : new SwitchOrchestrator(locator, store, operationLock, clock, reporter, config,
                    new FollowerCoordinator(followerLocator)).Run(command);
            if (result.ExitCode == ExitCodes.Success && config.Feedback.SuccessSound) Feedback.Success();
            else if (result.ExitCode != ExitCodes.Success && result.Outcome != Outcomes.Busy && config.Feedback.ErrorSound) Feedback.Error();
            return result.ExitCode;
        }

        if (command.Kind is CommandKind.Followers or CommandKind.EnrollFollower)
        {
            var followerReport = followerCommands.Run(command, report => WriteReport(command, report, clock));
            if (followerReport.Outcome == Outcomes.Busy && command.OutputPath is not null)
                WriteReport(command, followerReport, clock);
            return followerReport.ExitCode;
        }

        var maintenance = new MaintenanceCommands(locator, store, operationLock, configStore);
        var report = command.Kind switch
        {
            CommandKind.Discover => maintenance.Discover(),
            CommandKind.Status => maintenance.Status(),
            CommandKind.Diagnose => maintenance.Diagnose(),
            CommandKind.Enroll => maintenance.Enroll(command.DevicePath!, command.EdidHash!, command.ReplaceEnrollment),
            _ => throw new ArgumentOutOfRangeException(nameof(command)),
        };
        WriteReport(command, report, clock);
        return report.ExitCode;
    }

    private static void WriteReport(Command command, CommandReport report, IClock clock)
    {
        var body = new
        {
            generatedAtUtc = clock.UtcNow,
            version = typeof(Program).Assembly.GetName().Version?.ToString(),
            command = command.Kind.ToString().ToLowerInvariant(),
            report.Outcome,
            report.ExitCode,
            report.Details,
        };

        if (command.OutputPath is { } output) new ReportWriter(AppPaths.Root).Write(output, body);
        // Enrollment has no --output; its evidence goes to last-result.json unless another operation owns it.
        else if (report.Outcome != Outcomes.Busy)
            AtomicFile.Write(AppPaths.LastResult, JsonSerializer.SerializeToUtf8Bytes(body, StrictJson.Output));
    }
}
