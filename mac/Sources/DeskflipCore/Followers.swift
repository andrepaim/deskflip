import Foundation

public enum DeviceProducts {
    public static let keyboard = "B359"
    public static let mouse = "B031"
}

public struct FollowerConfig: Equatable, Codable {
    public var name: String
    public var productId: String
    // SHA-256 of a stable IOKit identifier, or nil when IOKit exposes none (then exactly one product match is required).
    public var identityHash: String?
    public var targetChannel: Int
    public var targetHostName: String
    public init(name: String, productId: String, identityHash: String?, targetChannel: Int, targetHostName: String) {
        self.name = name; self.productId = productId; self.identityHash = identityHash
        self.targetChannel = targetChannel; self.targetHostName = targetHostName
    }
    public var identity: FollowerIdentity { FollowerIdentity(productId: productId.uppercased(), identityHash: identityHash) }
}

public struct FollowerIdentity: Hashable, Codable {
    public let productId: String
    public let identityHash: String?
    public init(productId: String, identityHash: String?) { self.productId = productId; self.identityHash = identityHash }

    /// An enrolled identity without a hash matches on product alone; with a hash, it must match exactly.
    public func accepts(_ discovered: FollowerIdentity) -> Bool {
        guard productId.caseInsensitiveCompare(discovered.productId) == .orderedSame else { return false }
        return identityHash == nil || identityHash == discovered.identityHash
    }
}

/// What the locator found, with platform facts for diagnosis. Never raw serials or registry paths.
public struct DiscoveredFollower: Codable, Equatable {
    public let identity: FollowerIdentity
    public let platform: [String: String]
    public init(identity: FollowerIdentity, platform: [String: String] = [:]) { self.identity = identity; self.platform = platform }
}

public enum LocatorError: Error, Equatable, CustomStringConvertible {
    case missingOrAmbiguous(count: Int)
    case accessDenied(native: Int32)
    public var description: String {
        switch self {
        case .missingOrAmbiguous(let count): return "missingOrAmbiguous(\(count))"
        case .accessDenied(let native): return "accessDenied(" + String(format: "0x%08x", UInt32(bitPattern: native)) + ")"
        }
    }
}

/// One Logitech HID device as the platform presents it. Diagnosis only: no serials or registry paths.
public struct HidDeviceSummary: Codable, Equatable {
    public let productId: String
    public let product: String
    public let transport: String
    public let primaryUsage: String
    public let usagePairs: [String]
    public let maxInputReportSize: Int?
    public let maxOutputReportSize: Int?
    public let isFollowerCandidate: Bool
    public init(productId: String, product: String, transport: String, primaryUsage: String, usagePairs: [String],
                maxInputReportSize: Int?, maxOutputReportSize: Int?, isFollowerCandidate: Bool) {
        self.productId = productId; self.product = product; self.transport = transport; self.primaryUsage = primaryUsage
        self.usagePairs = usagePairs; self.maxInputReportSize = maxInputReportSize; self.maxOutputReportSize = maxOutputReportSize
        self.isFollowerCandidate = isFollowerCandidate
    }
}

public struct HidOverview: Codable, Equatable {
    public let totalDevices: Int
    public let logitech: [HidDeviceSummary]
    public init(totalDevices: Int, logitech: [HidDeviceSummary]) { self.totalDevices = totalDevices; self.logitech = logitech }
}

public protocol FollowerLocator: AnyObject {
    // Only Logitech 046D devices exposing usage page FF43 / usage 0202.
    func discover() throws -> [DiscoveredFollower]
    // Re-enumerate and require one exact match. No enumeration-order fallback.
    func openUnique(_ identity: FollowerIdentity) throws -> FollowerSession
    // Read-only platform status (for example the Input Monitoring check), for reports only.
    func accessStatus() -> String
    // Read-only: every Logitech HID device visible, matching or not, to diagnose discovery.
    func overview() -> HidOverview
}

public enum FollowerSelection {
    /// Index of the single accepted candidate; zero or several refuses.
    public static func unique(_ candidates: [FollowerIdentity], for identity: FollowerIdentity) throws -> Int {
        let matches = candidates.indices.filter { identity.accepts(candidates[$0]) }
        guard matches.count == 1 else { throw LocatorError.missingOrAmbiguous(count: matches.count) }
        return matches[0]
    }
}

public struct FollowerResult: Equatable, Codable {
    public var name: String
    public var preflight: String
    public var commandSent: Bool
    public var observation: String
    public var sendResult: String
    public var diagnostics: FollowerDiagnostics?
    public var problem: String?
    public init(name: String, preflight: String = "NotChecked", commandSent: Bool = false, observation: String = "NotSent",
                sendResult: String = "NotSent", diagnostics: FollowerDiagnostics? = nil, problem: String? = nil) {
        self.name = name; self.preflight = preflight; self.commandSent = commandSent; self.observation = observation
        self.sendResult = sendResult; self.diagnostics = diagnostics; self.problem = problem
    }
}

/// Preflight every device, then send each at most once. Sessions stay open from preflight until close().
/// Followers never become recovery authority; nothing here is persisted except the derived report.
public final class FollowerOperation {
    private let devices: [FollowerConfig]
    private var sessions: [FollowerSession?]
    public private(set) var results: [FollowerResult]
    private var preflighted = false
    private var sent = false

    public init(devices: [FollowerConfig]) {
        // Keyboard first and mouse last: the mouse carries the trigger button.
        self.devices = devices.enumerated().sorted { a, b in
            let ra = FollowerOperation.rank(a.element), rb = FollowerOperation.rank(b.element)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map { $0.element }
        sessions = Array(repeating: nil, count: devices.count)
        results = self.devices.map { FollowerResult(name: $0.name) }
    }

    private static func rank(_ device: FollowerConfig) -> Int {
        switch device.productId.uppercased() {
        case DeviceProducts.keyboard: return 0
        case DeviceProducts.mouse: return 2
        default: return 1
        }
    }

    public var allReady: Bool { preflighted && results.allSatisfy { $0.preflight == "Ready" || $0.preflight == "AlreadyThere" } }

    public func preflight(locator: FollowerLocator) {
        precondition(!preflighted, "Preflight runs once per operation.")
        preflighted = true
        for i in devices.indices {
            let device = devices[i]
            do {
                let session = try locator.openUnique(device.identity)
                sessions[i] = session
                let state = try session.readState()
                if !(1...3).contains(state.slotCount) || state.currentChannel < 1 || state.currentChannel > state.slotCount
                    || device.targetChannel > state.slotCount {
                    results[i].preflight = "InvalidChannels"
                } else if state.currentChannel == device.targetChannel {
                    results[i].preflight = "AlreadyThere"
                    results[i].observation = "AlreadyThere"
                } else {
                    let slot = try session.readHost(device.targetChannel)
                    results[i].preflight = slot.channel != device.targetChannel ? "InvalidChannel"
                        : !slot.paired ? "Unpaired"
                        : slot.hostName != device.targetHostName ? "HostMismatch" : "Ready"
                }
            } catch let error as LocatorError {
                results[i].preflight = "MissingOrAmbiguous"
                results[i].problem = error.description
            } catch {
                results[i].preflight = "Unavailable"
                results[i].problem = Self.describe(error)
            }
            results[i].diagnostics = sessions[i]?.diagnostics
        }
    }

    public func markDryRun() {
        guard allReady else { return }
        for i in results.indices where results[i].preflight == "Ready" { results[i].observation = "WouldSend" }
    }

    /// Exactly one change-host attempt per Ready device, never retried, then a bounded departure observation.
    public func sendAll() {
        guard allReady, !sent else { return }
        sent = true
        for i in devices.indices where results[i].preflight == "Ready" {
            // Mark before entering native code: a thrown/failed write may still have changed the host.
            results[i].commandSent = true
            results[i].sendResult = "Unverified"
            results[i].observation = "Unknown"
            do {
                try sessions[i]!.changeHost(devices[i].targetChannel)
                results[i].sendResult = "Accepted"
            } catch {
                results[i].problem = Self.describe(error)
            }
        }
        for i in devices.indices where results[i].commandSent {
            let observation = sessions[i]!.observeDeparture(budgetMs: 2000)
            results[i].observation = observation == "Left" || observation == "StillHere" ? observation : "Unknown"
            results[i].diagnostics = sessions[i]!.diagnostics
            if results[i].diagnostics?.changeHostError != nil { results[i].sendResult = "Rejected" }
        }
    }

    public func close() {
        for i in sessions.indices {
            sessions[i]?.close()
            sessions[i] = nil
        }
    }

    public var succeeded: Bool {
        !results.isEmpty && results.allSatisfy { $0.sendResult != "Rejected" && ($0.observation == "Left" || $0.observation == "AlreadyThere") }
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? HidppError { return error.description }
        if let error = error as? LocatorError { return error.description }
        return String(describing: type(of: error))
    }
}
