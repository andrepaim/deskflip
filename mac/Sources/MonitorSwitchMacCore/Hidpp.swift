import Foundation

// Transport is injectable for hardware-free tests. There is no raw-report command or configuration.
public protocol HidppTransport: AnyObject {
    func write(_ report: [UInt8], timeoutMs: Int64) throws
    func read(timeoutMs: Int64) throws -> [UInt8]
    func close()
}

public protocol MonotonicClock: AnyObject {
    var monotonicMs: Int64 { get }
    var wallClockMs: Int64 { get }
    func delay(ms: Int64)
}

public enum HidppError: Error, Equatable, CustomStringConvertible {
    case invalidArgument
    case timeout
    case disconnected
    case io(native: Int32?)
    case queryRejected(code: UInt8)
    case featureUnavailable
    case invalidHostState
    case invalidHostCount
    case ambiguousFeatureIndexes
    case invalidHostName
    case changeHostAlreadyAttempted
    case preflightRequired

    // Numeric codes only: never paths, serials or host names.
    public var description: String {
        switch self {
        case .invalidArgument: return "invalidArgument"
        case .timeout: return "timeout"
        case .disconnected: return "disconnected"
        case .io(let native): return "io(\(native.map { String(format: "0x%08x", UInt32(bitPattern: $0)) } ?? "nil"))"
        case .queryRejected(let code): return "queryRejected(\(code))"
        case .featureUnavailable: return "featureUnavailable"
        case .invalidHostState: return "invalidHostState"
        case .invalidHostCount: return "invalidHostCount"
        case .ambiguousFeatureIndexes: return "ambiguousFeatureIndexes"
        case .invalidHostName: return "invalidHostName"
        case .changeHostAlreadyAttempted: return "changeHostAlreadyAttempted"
        case .preflightRequired: return "preflightRequired"
        }
    }
}

public enum HidppFeature: UInt16 { case changeHost = 0x1814, hostsInfo = 0x1815 }
public enum HidppReply: Equatable { case unrelated, match, error }

public enum HidppPackets {
    public static let softwareId: UInt8 = 0xB
    public static let reportLength = 20

    public static func feature(_ feature: HidppFeature) -> [UInt8] {
        packet(0, 0, [UInt8(feature.rawValue >> 8), UInt8(feature.rawValue & 0xFF)])
    }
    public static func state(_ index: UInt8) throws -> [UInt8] { packet(try featureIndex(index), 0, []) }
    public static func changeHost(_ index: UInt8, channel: Int) throws -> [UInt8] {
        packet(try featureIndex(index), 1, [try host(channel)])
    }
    public static func hostsSummary(_ index: UInt8) throws -> [UInt8] { packet(try featureIndex(index), 0, []) }
    public static func hostInfo(_ index: UInt8, channel: Int) throws -> [UInt8] {
        packet(try featureIndex(index), 1, [try host(channel)])
    }
    public static func hostName(_ index: UInt8, channel: Int, offset: UInt8) throws -> [UInt8] {
        packet(try featureIndex(index), 3, [try host(channel), offset])
    }

    private static func host(_ channel: Int) throws -> UInt8 {
        guard (1...3).contains(channel) else { throw HidppError.invalidArgument }
        return UInt8(channel - 1)
    }
    private static func featureIndex(_ index: UInt8) throws -> UInt8 {
        guard index > 0 && index < 255 else { throw HidppError.invalidArgument }
        return index
    }
    private static func packet(_ index: UInt8, _ function: UInt8, _ parameters: [UInt8]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: reportLength)
        bytes[0] = 0x11; bytes[1] = 0xFF; bytes[2] = index; bytes[3] = (function << 4) | softwareId
        for (offset, value) in parameters.enumerated() { bytes[4 + offset] = value }
        return bytes
    }

    public static func match(_ request: [UInt8], _ reply: [UInt8]) -> HidppReply {
        guard request.count == reportLength, reply.count == reportLength, reply[0] == 0x11, reply[1] == 0xFF else {
            return .unrelated
        }
        if reply[2] == 0xFF && reply[3] == request[2] && reply[4] == request[3] { return .error }
        return reply[2] == request[2] && reply[3] == request[3] ? .match : .unrelated
    }
}

public struct HostState: Equatable, Codable {
    public let slotCount: Int
    public let currentChannel: Int
    public init(slotCount: Int, currentChannel: Int) { self.slotCount = slotCount; self.currentChannel = currentChannel }
}

public struct HostSlot: Equatable, Codable {
    public let channel: Int
    public let paired: Bool
    public let hostName: String?
    public init(channel: Int, paired: Bool, hostName: String?) {
        self.channel = channel; self.paired = paired; self.hostName = hostName
    }
}

// Only protocol metadata/counters, never raw reports, identifiers or host names.
public struct FollowerDiagnostics: Equatable, Codable {
    public var changeHostIndex: UInt8?
    public var changeHostVersion: UInt8?
    public var hostsInfoIndex: UInt8?
    public var lastCurrentChannel: Int?
    public var stateReplies = 0
    public var timeouts = 0
    public var ioFailures = 0
    public var lastNativeError: Int32?
    public var lastQueryError: UInt8?
    public var changeHostError: UInt8?
    public init() {}
}

public protocol FollowerSession: AnyObject {
    var diagnostics: FollowerDiagnostics { get }
    func readState() throws -> HostState
    func readHost(_ channel: Int) throws -> HostSlot
    func changeHost(_ channel: Int) throws
    // Bounded by the supplied budget; silence alone is Unknown, explicit disconnect is Left.
    func observeDeparture(budgetMs: Int64) -> String
    func close()
}

/// Only design v1.2 §5 queries and the single change-host write. Feature indexes live for one session.
public final class HidppSession: FollowerSession {
    private let transport: HidppTransport
    private let clock: MonotonicClock
    private var changeIndex: UInt8?
    private var hostsIndex: UInt8?
    private var changeAttempted = false
    private var changeRequest: [UInt8]?
    public private(set) var diagnostics = FollowerDiagnostics()

    public init(transport: HidppTransport, clock: MonotonicClock) {
        self.transport = transport
        self.clock = clock
    }

    private func resolve(_ feature: HidppFeature) throws -> UInt8 {
        let reply = try query(HidppPackets.feature(feature))
        guard reply[4] != 0 && reply[4] != 255 else { throw HidppError.featureUnavailable }
        if feature == .changeHost { diagnostics.changeHostVersion = reply[6] }
        return reply[4]
    }

    private func changeHostIndex() throws -> UInt8 {
        if let index = changeIndex { return index }
        let index = try resolve(.changeHost)
        changeIndex = index
        diagnostics.changeHostIndex = index
        return index
    }

    public func readState() throws -> HostState {
        try decodeState(try query(HidppPackets.state(try changeHostIndex())))
    }

    private func decodeState(_ reply: [UInt8]) throws -> HostState {
        guard (1...3).contains(reply[4]), reply[5] < reply[4] else { throw HidppError.invalidHostState }
        let current = Int(reply[5]) + 1
        diagnostics.lastCurrentChannel = current
        diagnostics.stateReplies += 1
        return HostState(slotCount: Int(reply[4]), currentChannel: current)
    }

    public func readHost(_ channel: Int) throws -> HostSlot {
        // A late duplicate root reply must never make the hosts-info function 1 become change-host.
        let change = try changeHostIndex()
        if hostsIndex == nil {
            hostsIndex = try resolve(.hostsInfo)
            diagnostics.hostsInfoIndex = hostsIndex
        }
        guard let index = hostsIndex, index != change else { throw HidppError.ambiguousFeatureIndexes }
        let summary = try query(HidppPackets.hostsSummary(index))
        guard (1...3).contains(summary[6]), channel >= 1, channel <= Int(summary[6]) else { throw HidppError.invalidHostCount }
        let host = UInt8(channel - 1)
        let slot = try query(HidppPackets.hostInfo(index, channel: channel)) { $0[4] == host }
        if slot[5] == 0 { return HostSlot(channel: channel, paired: false, hostName: nil) }
        if summary[4] & 1 == 0 { return HostSlot(channel: channel, paired: true, hostName: nil) }
        let length = Int(slot[8])
        var name = [UInt8]()
        var offset = 0
        while offset < length {
            let page = UInt8(offset)
            let part = try query(HidppPackets.hostName(index, channel: channel, offset: page)) { $0[4] == host && $0[5] == page }
            name.append(contentsOf: part[6..<(6 + min(14, length - offset))])
            offset += 14
        }
        // Strict UTF-8: a lossy decode would not round-trip to the same bytes.
        let text = String(decoding: name, as: UTF8.self)
        guard Array(text.utf8) == name else { throw HidppError.invalidHostName }
        return HostSlot(channel: channel, paired: true, hostName: text)
    }

    public func changeHost(_ channel: Int) throws {
        guard !changeAttempted else { throw HidppError.changeHostAlreadyAttempted }
        guard let index = changeIndex else { throw HidppError.preflightRequired }
        let packet = try HidppPackets.changeHost(index, channel: channel)
        changeAttempted = true
        changeRequest = packet
        do { try transport.write(packet, timeoutMs: 500) }
        catch { record(error); throw error }
        // No success acknowledgement exists. observeDeparture can capture a rejection, never resend.
    }

    public func observeDeparture(budgetMs: Int64) -> String {
        guard changeAttempted, let index = changeIndex, let stateRequest = try? HidppPackets.state(index) else { return "Unknown" }
        let deadline = clock.monotonicMs + min(max(budgetMs, 0), 2000)
        var observation = "Unknown"
        // Bounded passive window before any state query; a rejection frame may arrive here.
        let passiveDeadline = min(deadline, clock.monotonicMs + 250)
        while clock.monotonicMs < passiveDeadline {
            do { captureChangeError(try transport.read(timeoutMs: passiveDeadline - clock.monotonicMs)) }
            catch HidppError.disconnected { return "Left" }
            catch { record(error); break }
        }
        while clock.monotonicMs < deadline {
            do {
                _ = try decodeState(try queryOnce(stateRequest, nil, min(500, deadline - clock.monotonicMs)))
                observation = "StillHere"
            } catch HidppError.disconnected {
                return "Left"
            } catch {
                observation = "Unknown"
            }
            let remaining = deadline - clock.monotonicMs
            if remaining > 0 { clock.delay(ms: min(100, remaining)) }
        }
        return observation
    }

    private func query(_ request: [UInt8], _ additionalMatch: (([UInt8]) -> Bool)? = nil) throws -> [UInt8] {
        do { return try queryOnce(request, additionalMatch, 500) }
        catch HidppError.timeout { return try queryOnce(request, additionalMatch, 500) }
    }

    private func queryOnce(_ request: [UInt8], _ additionalMatch: (([UInt8]) -> Bool)?, _ timeoutMs: Int64) throws -> [UInt8] {
        do { return try exchange(request, additionalMatch, timeoutMs) }
        catch { record(error); throw error }
    }

    private func exchange(_ request: [UInt8], _ additionalMatch: (([UInt8]) -> Bool)?, _ timeoutMs: Int64) throws -> [UInt8] {
        guard timeoutMs > 0 else { throw HidppError.timeout }
        let deadline = clock.monotonicMs + timeoutMs
        try transport.write(request, timeoutMs: timeoutMs)
        while clock.monotonicMs < deadline {
            let reply = try transport.read(timeoutMs: deadline - clock.monotonicMs)
            let match = HidppPackets.match(request, reply)
            captureChangeError(reply)
            if match == .error { throw HidppError.queryRejected(code: reply[5]) }
            if match == .match && (additionalMatch?(reply) ?? true) { return reply }
        }
        throw HidppError.timeout
    }

    public func close() { transport.close() }

    private func captureChangeError(_ reply: [UInt8]) {
        if let request = changeRequest, HidppPackets.match(request, reply) == .error {
            diagnostics.changeHostError = reply[5]
        }
    }

    private func record(_ error: Error) {
        switch error {
        case HidppError.timeout: diagnostics.timeouts += 1
        case HidppError.queryRejected(let code): diagnostics.lastQueryError = code
        case HidppError.io(let native): diagnostics.ioFailures += 1; diagnostics.lastNativeError = native
        case HidppError.disconnected: break
        default: break
        }
    }
}
