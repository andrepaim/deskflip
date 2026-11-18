import Foundation

public enum ExitCodes {
    public static let success: Int32 = 0
    public static let busyOrCooldown: Int32 = 2
    public static let invalidConfiguration: Int32 = 10
    public static let displayUnavailable: Int32 = 11
    public static let followIncomplete: Int32 = 17
    public static let monitorFailed: Int32 = 19
    public static let internalError: Int32 = 20
    public static let unsupported: Int32 = 21
}

public enum AppInfo {
    public static let version = "0.1.1"
    public static let cooldownMs: Int64 = 3000
    public static let defaultM1ddcPath = "/opt/homebrew/bin/m1ddc"
    public static let toolTimeoutMs: Int64 = 10_000
}

public protocol LockLease: AnyObject { func release() }
public protocol OperationLock: AnyObject {
    // Nonblocking: nil means another run holds it.
    func tryAcquire() -> LockLease?
}

/// Per-user files. Config writes are atomic and keep one previous generation.
public protocol AppStore: AnyObject {
    func readConfig() throws -> String?
    func writeConfig(_ text: String) throws
    func readLastResult() -> String?
    func writeLastResult(_ text: String) throws
    func appendLog(_ line: String) throws
    func appendProbe(_ line: String) throws
}

public enum Command: Equatable {
    case button(dryRun: Bool)
    case followers
    case displays(m1ddcPath: String?)
    case enroll(displayId: String, keyboardChannel: Int, mouseChannel: Int, m1ddcPath: String, replace: Bool)
    case follow(device: String?)
    case probeTrigger
    case version
}

public enum CommandLineParser {
    public static func parse(_ arguments: [String]) throws -> Command {
        guard let verb = arguments.first else { return .button(dryRun: false) }
        var options = [String: String]()
        var flags = Set<String>()
        var rest = Array(arguments.dropFirst())
        let valued: Set<String>
        let allowedFlags: Set<String>
        switch verb {
        case "--dry-run": valued = []; allowedFlags = []
        case "followers", "probe-trigger", "--version": valued = []; allowedFlags = []
        case "displays": valued = ["--m1ddc"]; allowedFlags = []
        case "enroll": valued = ["--display", "--keyboard-channel", "--mouse-channel", "--m1ddc"]; allowedFlags = ["--replace"]
        case "follow": valued = ["--device"]; allowedFlags = []
        default: throw ConfigError("Unknown command.")
        }
        while !rest.isEmpty {
            let name = rest.removeFirst()
            if allowedFlags.contains(name) {
                guard flags.insert(name).inserted else { throw ConfigError("Repeated option \(name).") }
            } else if valued.contains(name) {
                guard !rest.isEmpty, options[name] == nil else { throw ConfigError("Option \(name) needs one value.") }
                options[name] = rest.removeFirst()
            } else {
                throw ConfigError("Unknown option.")
            }
        }
        switch verb {
        case "--dry-run": return .button(dryRun: true)
        case "followers": return .followers
        case "probe-trigger": return .probeTrigger
        case "--version": return .version
        case "displays": return .displays(m1ddcPath: options["--m1ddc"])
        case "follow":
            if let device = options["--device"], device != "keyboard" && device != "mouse" {
                throw ConfigError("--device must be keyboard or mouse.")
            }
            return .follow(device: options["--device"])
        default:
            guard let display = options["--display"], ConfigParser.isDisplayId(display),
                  let keyboard = options["--keyboard-channel"].flatMap(Int.init), (1...3).contains(keyboard),
                  let mouse = options["--mouse-channel"].flatMap(Int.init), (1...3).contains(mouse)
            else { throw ConfigError("enroll needs --display ID --keyboard-channel 1-3 --mouse-channel 1-3.") }
            return .enroll(displayId: display, keyboardChannel: keyboard, mouseChannel: mouse,
                           m1ddcPath: options["--m1ddc"] ?? AppInfo.defaultM1ddcPath, replace: flags.contains("--replace"))
        }
    }
}

public struct RunReport: Codable, Equatable {
    public var version = AppInfo.version
    public var operationId: String
    public var command: String
    public var outcome: String
    public var exitCode: Int32
    public var startedAtMs: Int64
    public var finishedAtMs: Int64 = 0
    public var elapsedMs: Int64 = 0
    public var monitor: MonitorRecord?
    public var followers: [FollowerResult] = []
    public var detail: String?
}

struct InventoryEntry: Codable {
    var identity: FollowerIdentity
    var platform: [String: String]
    var enrolledName: String?
    var state: HostState?
    var slots: [HostSlot] = []
    var diagnostics: FollowerDiagnostics?
    var problem: String?
}

struct InventoryReport: Codable {
    var command = "followers"
    var accessStatus: String
    var hid: HidOverview
    var devices: [InventoryEntry]
    var enrolledAbsent: [String]
    var configProblem: String?
}

enum InventorySummary {
    /// Short plain-text lines the owner can read out when the JSON cannot be copied. No host names.
    static func lines(_ report: InventoryReport) -> [String] {
        var lines = ["SUMMARY \(report.accessStatus); HID devices visible: \(report.hid.totalDevices); "
            + "Logitech: \(report.hid.logitech.count); followers found: \(report.devices.count)"]
        for device in report.hid.logitech.sorted(by: { $0.productId < $1.productId }) {
            lines.append("  LOGI \(device.productId) \(device.transport.isEmpty ? "?" : device.transport) primary \(device.primaryUsage) "
                + "pairs \(device.usagePairs.isEmpty ? "-" : device.usagePairs.joined(separator: ",")) "
                + "in/out \(device.maxInputReportSize.map(String.init) ?? "?")/\(device.maxOutputReportSize.map(String.init) ?? "?")"
                + (device.isFollowerCandidate ? " HIDPP" : ""))
        }
        for entry in report.devices {
            let paired = entry.slots.map { "\($0.channel):\($0.paired ? ($0.hostName == nil ? "paired" : "named") : "empty")" }
            lines.append("  FOLLOWER \(entry.identity.productId) id=\(entry.platform["identitySource"] ?? "?") "
                + "channel=\(entry.state.map { String($0.currentChannel) } ?? "?") slots=\(paired.joined(separator: ",")) "
                + "problem=\(entry.problem ?? "none")")
        }
        return lines
    }
}

public final class App {
    private let store: AppStore
    private let lock: OperationLock
    private let locator: FollowerLocator
    private let tools: ToolRunner
    private let clock: MonotonicClock
    private let console: (String) -> Void
    private let processId: Int32

    public init(store: AppStore, lock: OperationLock, locator: FollowerLocator, tools: ToolRunner,
                clock: MonotonicClock, processId: Int32, console: @escaping (String) -> Void) {
        self.store = store; self.lock = lock; self.locator = locator; self.tools = tools
        self.clock = clock; self.processId = processId; self.console = console
    }

    public func run(_ arguments: [String]) -> Int32 {
        let command: Command
        do { command = try CommandLineParser.parse(arguments) }
        catch { console("error: \(error)"); return ExitCodes.invalidConfiguration }
        switch command {
        case .version: console(AppInfo.version); return ExitCodes.success
        case .probeTrigger: return probe()
        case .displays(let path): return displays(path)
        case .followers: return withLock { inventory() }
        case .enroll(let display, let keyboard, let mouse, let path, let replace):
            return withLock { enroll(display, keyboard, mouse, path, replace) }
        case .button(let dryRun): return operation(dryRun ? "dry-run" : "button") { report in try button(dryRun, &report) }
        case .follow(let device): return operation("follow") { report in try follow(device, &report) }
        }
    }

    // MARK: Button action (MAC-HELPER-PLAN §7)

    private func button(_ dryRun: Bool, _ report: inout RunReport) throws {
        if !dryRun, let last = lastFinishedAt(), case let elapsed = clock.wallClockMs - last, elapsed >= 0, elapsed < AppInfo.cooldownMs {
            report.outcome = "Debounced"; report.exitCode = ExitCodes.busyOrCooldown
            return
        }
        guard let config = try loadConfig(&report) else { return }
        guard checkDisplay(config.monitor, &report) else { return }

        let operation = FollowerOperation(devices: config.devices)
        defer { operation.close(); report.followers = operation.results }
        operation.preflight(locator: locator)
        guard operation.allReady else {
            report.outcome = "PreflightRefused"; report.exitCode = ExitCodes.followIncomplete
            return
        }
        if dryRun {
            operation.markDryRun()
            report.monitor = MonitorRecord()
            report.outcome = "DryRun"; report.exitCode = ExitCodes.success
            report.detail = "Would set input \(M1ddc.pcInput) on the enrolled display, then send ready devices."
            return
        }
        // Exactly one monitor command. Not readable back on the Mac, so "accepted", never Confirmed.
        let arguments = try M1ddc.switchToPCArguments(displayId: config.monitor.displayId)
        let output = tools.run(executable: config.monitor.m1ddcPath, arguments: arguments, timeoutMs: AppInfo.toolTimeoutMs)
        report.monitor = MonitorRecord(attempted: true, accepted: output.succeeded, exitStatus: output.exitStatus, timedOut: output.timedOut)
        guard output.succeeded else {
            report.outcome = "MonitorFailed"; report.exitCode = ExitCodes.monitorFailed
            return
        }
        operation.sendAll()
        report.followers = operation.results
        report.outcome = operation.succeeded ? "Completed" : "FollowIncomplete"
        report.exitCode = operation.succeeded ? ExitCodes.success : ExitCodes.followIncomplete
    }

    private func follow(_ device: String?, _ report: inout RunReport) throws {
        guard let config = try loadConfig(&report) else { return }
        let devices = config.devices.filter { device == nil || $0.name == device }
        guard !devices.isEmpty else {
            report.outcome = "InvalidConfiguration"; report.exitCode = ExitCodes.invalidConfiguration
            report.detail = "That device is not enrolled."
            return
        }
        let operation = FollowerOperation(devices: devices)
        defer { operation.close(); report.followers = operation.results }
        operation.preflight(locator: locator)
        guard operation.allReady else {
            report.outcome = "PreflightRefused"; report.exitCode = ExitCodes.followIncomplete
            return
        }
        operation.sendAll()
        report.followers = operation.results
        report.outcome = operation.succeeded ? "Followed" : "FollowIncomplete"
        report.exitCode = operation.succeeded ? ExitCodes.success : ExitCodes.followIncomplete
    }

    private func operation(_ name: String, _ body: (inout RunReport) throws -> Void) -> Int32 {
        let start = clock.monotonicMs
        var report = RunReport(operationId: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                               command: name, outcome: "Busy", exitCode: ExitCodes.busyOrCooldown, startedAtMs: clock.wallClockMs)
        guard let lease = lock.tryAcquire() else {
            finish(&report, start, persistResult: false)
            return report.exitCode
        }
        defer { lease.release() }
        do { try body(&report) }
        catch {
            report.outcome = "InternalError"; report.exitCode = ExitCodes.internalError
            report.detail = FollowerOperation.describe(error)
        }
        // Busy and Debounced must not extend the cooldown window.
        finish(&report, start, persistResult: report.outcome != "Debounced")
        return report.exitCode
    }

    private func finish(_ report: inout RunReport, _ start: Int64, persistResult: Bool) {
        report.finishedAtMs = clock.wallClockMs
        report.elapsedMs = clock.monotonicMs - start
        let pretty = JSONEncoder(), compact = JSONEncoder()
        pretty.outputFormatting = [.prettyPrinted, .sortedKeys]
        compact.outputFormatting = [.sortedKeys]
        if persistResult, let data = try? pretty.encode(report) { try? store.writeLastResult(String(decoding: data, as: UTF8.self) + "\n") }
        if let data = try? compact.encode(report) { try? store.appendLog(String(decoding: data, as: UTF8.self)) }
        console("\(report.command): \(report.outcome) (exit \(report.exitCode), \(report.elapsedMs) ms)")
    }

    private func lastFinishedAt() -> Int64? {
        guard let text = store.readLastResult(),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let value = object["finishedAtMs"] as? NSNumber else { return nil }
        return value.int64Value
    }

    private func loadConfig(_ report: inout RunReport) throws -> MacConfig? {
        do {
            guard let text = try store.readConfig() else {
                report.outcome = "InvalidConfiguration"; report.exitCode = ExitCodes.invalidConfiguration
                report.detail = "Not enrolled."
                return nil
            }
            return try ConfigParser.parse(text)
        } catch let error as ConfigError {
            report.outcome = "InvalidConfiguration"; report.exitCode = ExitCodes.invalidConfiguration
            report.detail = error.reason
            return nil
        }
    }

    private func checkDisplay(_ monitor: MonitorConfig, _ report: inout RunReport) -> Bool {
        let list = tools.run(executable: monitor.m1ddcPath, arguments: M1ddc.listArguments, timeoutMs: AppInfo.toolTimeoutMs)
        let count = list.succeeded ? M1ddc.countMatches(listOutput: list.output, displayId: monitor.displayId) : 0
        guard count == 1 else {
            report.outcome = "DisplayUnavailable"; report.exitCode = ExitCodes.displayUnavailable
            report.detail = list.succeeded ? "Enrolled display matched \(count) listed displays." : "m1ddc display list failed."
            return false
        }
        return true
    }

    // MARK: Maintenance commands

    private func withLock(_ body: () -> Int32) -> Int32 {
        guard let lease = lock.tryAcquire() else { console("Busy: another run holds the lock."); return ExitCodes.busyOrCooldown }
        defer { lease.release() }
        return body()
    }

    private func inventory() -> Int32 {
        var config: MacConfig?
        var configProblem: String?
        do { config = try store.readConfig().map(ConfigParser.parse) } catch { configProblem = String(describing: error) }
        let discovered: [DiscoveredFollower]
        do { discovered = try locator.discover() }
        catch {
            console("Discovery failed: \(FollowerOperation.describe(error)); access: \(locator.accessStatus())")
            return ExitCodes.internalError
        }
        var entries = [InventoryEntry]()
        var seen = Set<FollowerIdentity>()
        for device in discovered where seen.insert(device.identity).inserted {
            var entry = InventoryEntry(identity: device.identity, platform: device.platform,
                                       enrolledName: config?.devices.first { $0.identity.accepts(device.identity) }?.name)
            var session: FollowerSession?
            do {
                session = try locator.openUnique(device.identity)
                let state = try session!.readState()
                entry.state = state
                for channel in 1...state.slotCount { entry.slots.append(try session!.readHost(channel)) }
            } catch {
                entry.problem = FollowerOperation.describe(error)
            }
            entry.diagnostics = session?.diagnostics
            session?.close()
            entries.append(entry)
        }
        let absent = (config?.devices ?? []).filter { enrolled in !discovered.contains { enrolled.identity.accepts($0.identity) } }.map(\.name)
        let report = InventoryReport(accessStatus: locator.accessStatus(), hid: locator.overview(), devices: entries,
                                     enrolledAbsent: absent, configProblem: configProblem)
        printJSON(report)
        InventorySummary.lines(report).forEach(console)
        return ExitCodes.success
    }

    private func displays(_ path: String?) -> Int32 {
        let executable = path ?? ((try? store.readConfig()).flatMap { $0 }.flatMap { try? ConfigParser.parse($0) }?.monitor.m1ddcPath
                                  ?? AppInfo.defaultM1ddcPath)
        guard executable.hasPrefix("/") else { console("error: m1ddc path must be absolute."); return ExitCodes.invalidConfiguration }
        let output = tools.run(executable: executable, arguments: M1ddc.listArguments, timeoutMs: AppInfo.toolTimeoutMs)
        console("m1ddc: \(executable)")
        console(output.output)
        guard output.succeeded else {
            console("m1ddc display list failed (exit \(output.exitStatus.map(String.init) ?? "none")\(output.timedOut ? ", timed out" : "")).")
            return ExitCodes.displayUnavailable
        }
        return ExitCodes.success
    }

    private func enroll(_ displayId: String, _ keyboardChannel: Int, _ mouseChannel: Int, _ m1ddcPath: String, _ replace: Bool) -> Int32 {
        func refuse(_ reason: String, _ code: Int32 = ExitCodes.invalidConfiguration) -> Int32 { console("Refused: \(reason)"); return code }
        do {
            if try store.readConfig() != nil && !replace { return refuse("A config exists; replacing it requires --replace.") }
        } catch { return refuse("Existing config could not be read.") }
        guard m1ddcPath.hasPrefix("/") else { return refuse("m1ddc path must be absolute.") }
        let list = tools.run(executable: m1ddcPath, arguments: M1ddc.listArguments, timeoutMs: AppInfo.toolTimeoutMs)
        guard list.succeeded else { return refuse("m1ddc display list failed.", ExitCodes.displayUnavailable) }
        let displayMatches = M1ddc.countMatches(listOutput: list.output, displayId: displayId)
        guard displayMatches == 1 else { return refuse("Display identifier matched \(displayMatches) listed displays.", ExitCodes.displayUnavailable) }

        let discovered: [DiscoveredFollower]
        do { discovered = try locator.discover() } catch { return refuse("Discovery failed: \(FollowerOperation.describe(error)).", ExitCodes.internalError) }
        var devices = [FollowerConfig]()
        for (name, product, channel) in [("keyboard", DeviceProducts.keyboard, keyboardChannel), ("mouse", DeviceProducts.mouse, mouseChannel)] {
            let matches = discovered.filter { $0.identity.productId.caseInsensitiveCompare(product) == .orderedSame }
            guard matches.count == 1 else { return refuse("Exactly one \(name) (\(product)) must be present; found \(matches.count).") }
            let identity = matches[0].identity
            var session: FollowerSession?
            defer { session?.close() }
            do {
                session = try locator.openUnique(identity)
                let state = try session!.readState()
                guard channel <= state.slotCount else { return refuse("The \(name) has no channel \(channel).") }
                guard channel != state.currentChannel else {
                    return refuse("Channel \(channel) is the \(name)'s current channel (this Mac); enroll the PC channel.")
                }
                let slot = try session!.readHost(channel)
                guard slot.paired, let host = slot.hostName, ConfigParser.isHostName(host) else {
                    return refuse("The \(name)'s channel \(channel) must be paired and report a usable host name.")
                }
                devices.append(FollowerConfig(name: name, productId: product, identityHash: identity.identityHash,
                                              targetChannel: channel, targetHostName: host))
            } catch {
                return refuse("The \(name) could not be queried: \(FollowerOperation.describe(error)).", ExitCodes.internalError)
            }
        }
        let config = MacConfig(monitor: MonitorConfig(m1ddcPath: m1ddcPath, displayId: displayId), devices: devices)
        do {
            try ConfigParser.validate(config)
            try store.writeConfig(try ConfigParser.encode(config))
        } catch {
            return refuse("Config could not be written: \(error).")
        }
        // Explicitly requested report: the owner checks the captured PC host names here.
        for device in devices {
            console("Enrolled \(device.name): channel \(device.targetChannel), host \"\(device.targetHostName)\", identity \(device.identityHash == nil ? "product only" : "hashed")")
        }
        return ExitCodes.success
    }

    private func probe() -> Int32 {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date(timeIntervalSince1970: Double(clock.wallClockMs) / 1000))
        let line = "{\"timestampUtc\":\"\(timestamp)\",\"processId\":\(processId),\"version\":\"\(AppInfo.version)\"}"
        do { try store.appendProbe(line); return ExitCodes.success } catch { return ExitCodes.internalError }
    }

    private func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value) { console(String(decoding: data, as: UTF8.self)) }
    }
}
