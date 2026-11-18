import Foundation
@testable import MonitorSwitchMacCore

final class FakeClock: MonotonicClock {
    var monotonicMs: Int64 = 1_000
    var wallClockMs: Int64 = 1_800_000_000_000
    func delay(ms: Int64) { if ms > 0 { monotonicMs += ms; wallClockMs += ms } }
}

final class FakeTransport: HidppTransport {
    let clock: FakeClock
    var writes: [[UInt8]] = []
    var budgets: [Int64] = []
    var replies: [() throws -> [UInt8]] = []
    var onWrite: (([UInt8]) throws -> Void)?
    var notificationsForever = false
    var closed = 0
    init(clock: FakeClock) { self.clock = clock }

    func write(_ report: [UInt8], timeoutMs: Int64) throws {
        budgets.append(timeoutMs)
        writes.append(report)
        try onWrite?(report)
    }
    func read(timeoutMs: Int64) throws -> [UInt8] {
        budgets.append(timeoutMs)
        if !replies.isEmpty { clock.delay(ms: 1); return try replies.removeFirst()() }
        if notificationsForever { clock.delay(ms: min(10, timeoutMs)); return [UInt8](repeating: 0, count: 20) }
        clock.delay(ms: timeoutMs)
        throw HidppError.timeout
    }
    func close() { closed += 1 }
}

func reply(_ request: [UInt8], _ parameters: [UInt8]) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 20)
    for i in 0..<4 { bytes[i] = request[i] }
    for (i, value) in parameters.enumerated() { bytes[4 + i] = value }
    return bytes
}

func errorReply(_ request: [UInt8], _ code: UInt8) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 20)
    bytes[0] = 0x11; bytes[1] = 0xFF; bytes[2] = 0xFF; bytes[3] = request[2]; bytes[4] = request[3]; bytes[5] = code
    return bytes
}

final class FakeFollower: FollowerSession {
    var state = HostState(slotCount: 3, currentChannel: 1) // on the Mac; the PC is channel 2
    var slot: HostSlot
    var throwRead = false
    var throwSend = false
    var observation = "Left"
    var sends: [Int] = []
    var hostCalls = 0
    var closeCount = 0
    var onSend: (() -> Void)?
    var diagnostics = FollowerDiagnostics()

    init(targetChannel: Int, hostName: String) { slot = HostSlot(channel: targetChannel, paired: true, hostName: hostName) }

    func readState() throws -> HostState {
        if throwRead { throw HidppError.timeout }
        return state
    }
    func readHost(_ channel: Int) throws -> HostSlot { hostCalls += 1; return slot }
    func changeHost(_ channel: Int) throws {
        sends.append(channel)
        onSend?()
        if throwSend { throw HidppError.io(native: 5) }
    }
    func observeDeparture(budgetMs: Int64) -> String { observation }
    func close() { closeCount += 1 }
}

final class FakeLocator: FollowerLocator {
    var present: [FollowerIdentity] = []
    var followers: [FollowerIdentity: FakeFollower] = [:]
    var sendOrder: [String] = []
    var opened = 0

    @discardableResult
    func add(_ config: FollowerConfig, discoveredHash: String? = nil) -> FakeFollower {
        let identity = FollowerIdentity(productId: config.productId, identityHash: discoveredHash ?? config.identityHash)
        let follower = FakeFollower(targetChannel: config.targetChannel, hostName: config.targetHostName)
        follower.onSend = { [unowned self] in self.sendOrder.append(config.name) }
        present.append(identity)
        followers[identity] = follower
        return follower
    }

    func discover() throws -> [DiscoveredFollower] { present.map { DiscoveredFollower(identity: $0, platform: ["transport": "fake"]) } }
    func openUnique(_ identity: FollowerIdentity) throws -> FollowerSession {
        let index = try FollowerSelection.unique(present, for: identity)
        opened += 1
        return followers[present[index]]!
    }
    func accessStatus() -> String { "fake" }
    func overview() -> HidOverview {
        HidOverview(totalDevices: present.count + 1, logitech: present.map {
            HidDeviceSummary(productId: $0.productId, product: "", transport: "Bluetooth Low Energy", primaryUsage: "0001:0002",
                             usagePairs: ["0001:0002", "FF43:0202"], maxInputReportSize: 20, maxOutputReportSize: 20,
                             isFollowerCandidate: true)
        })
    }
}

final class FakeLease: LockLease {
    let owner: FakeLock
    init(_ owner: FakeLock) { self.owner = owner }
    func release() { owner.held = false }
}

final class FakeLock: OperationLock {
    var held = false
    func tryAcquire() -> LockLease? {
        guard !held else { return nil }
        held = true
        return FakeLease(self)
    }
}

final class FakeStore: AppStore {
    var config: String?
    var previousConfig: String?
    var lastResult: String?
    var logs: [String] = []
    var probes: [String] = []
    func readConfig() throws -> String? { config }
    func writeConfig(_ text: String) throws { previousConfig = config; config = text }
    func readLastResult() -> String? { lastResult }
    func writeLastResult(_ text: String) throws { lastResult = text }
    func appendLog(_ line: String) throws { logs.append(line) }
    func appendProbe(_ line: String) throws { probes.append(line) }
}

final class FakeTools: ToolRunner {
    var listOutput = "[1] LU28R55 (11111111-2222-3333-4444-555555555555)\n[2] Built-in (AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE)\n"
    var listStatus: Int32? = 0
    var switchStatus: Int32? = 0
    var switchTimedOut = false
    var calls: [(String, [String])] = []
    var onSwitch: (() -> Void)?
    var switchCalls: [[String]] { calls.map { $0.1 }.filter { $0.contains("set") } }

    func run(executable: String, arguments: [String], timeoutMs: Int64) -> ToolOutput {
        calls.append((executable, arguments))
        if arguments == M1ddc.listArguments { return ToolOutput(exitStatus: listStatus, output: listOutput) }
        onSwitch?()
        return ToolOutput(exitStatus: switchStatus, timedOut: switchTimedOut)
    }
}

enum TestData {
    static let displayId = "11111111-2222-3333-4444-555555555555"
    static let keyboard = FollowerConfig(name: "keyboard", productId: "B359", identityHash: String(repeating: "a", count: 64),
                                         targetChannel: 2, targetHostName: "pc-host")
    static let mouse = FollowerConfig(name: "mouse", productId: "B031", identityHash: String(repeating: "b", count: 64),
                                      targetChannel: 2, targetHostName: "pc-host")
    static let config = MacConfig(monitor: MonitorConfig(m1ddcPath: "/opt/homebrew/bin/m1ddc", displayId: displayId),
                                  devices: [mouse, keyboard])
    static var configText: String { try! ConfigParser.encode(config) }
}
