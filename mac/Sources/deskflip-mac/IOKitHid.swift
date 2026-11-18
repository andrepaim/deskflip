#if os(macOS)
import CryptoKit
import Foundation
import IOKit.hid
import DeskflipCore

// IOReturn values are function-like macros in C and are not imported into Swift.
enum IOKitReturn {
    static let notAttached = Int32(bitPattern: 0xE000_02D8)
    static let noDevice = Int32(bitPattern: 0xE000_02C0)
    static let timeout = Int32(bitPattern: 0xE000_02D6)
    static let notPermitted = Int32(bitPattern: 0xE000_02E2)
    static let notPrivileged = Int32(bitPattern: 0xE000_02C1)
}

enum HidKeys {
    static let vendor = 0x046D
    static let usagePage = 0xFF43
    static let usage = 0x0202
    // Stable per-device identifiers, in preference order. LocationID and UniqueID change between connections.
    static let identityKeys = ["SerialNumber", "PhysicalDeviceUniqueID"]
}

private func property(_ device: IOHIDDevice, _ key: String) -> Any? { IOHIDDeviceGetProperty(device, key as CFString) }
private func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? { (property(device, key) as? NSNumber)?.intValue }

final class IOKitFollowerLocator: FollowerLocator {
    private let clock: MonotonicClock
    private let manager: IOHIDManager

    private var settled = false

    init(clock: MonotonicClock) {
        self.clock = clock
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Match everything so the overview can report how many devices are visible at all; Logitech is filtered below.
        IOHIDManagerSetDeviceMatching(manager, nil)
    }

    /// Like hidapi: schedule the manager and let pending matching events run before copying devices.
    /// The manager is never opened, so no device is opened or seized by enumeration.
    private func allDevices() -> [IOHIDDevice] {
        if !settled {
            settled = true
            IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            let deadline = clock.monotonicMs + 500
            while clock.monotonicMs < deadline,
                  CFRunLoopRunInMode(.defaultMode, 0.05, true) == .handledSource {}
        }
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return Array(set)
    }

    private static func usageText(_ page: Int?, _ usage: Int?) -> String {
        guard let page, let usage else { return "?" }
        return String(format: "%04X:%04X", page, usage)
    }

    func overview() -> HidOverview {
        let devices = allDevices()
        let logitech = devices.filter { intProperty($0, kIOHIDVendorIDKey) == HidKeys.vendor }.map { device -> HidDeviceSummary in
            let pairs = ((property(device, kIOHIDDeviceUsagePairsKey) as? [[String: Any]]) ?? []).map {
                Self.usageText(($0[kIOHIDDeviceUsagePageKey] as? NSNumber)?.intValue, ($0[kIOHIDDeviceUsageKey] as? NSNumber)?.intValue)
            }
            let primary = Self.usageText(intProperty(device, kIOHIDPrimaryUsagePageKey), intProperty(device, kIOHIDPrimaryUsageKey))
            let target = Self.usageText(HidKeys.usagePage, HidKeys.usage)
            return HidDeviceSummary(productId: intProperty(device, kIOHIDProductIDKey).map { String(format: "%04X", $0) } ?? "?",
                                    product: (property(device, kIOHIDProductKey) as? String) ?? "",
                                    transport: (property(device, kIOHIDTransportKey) as? String) ?? "",
                                    primaryUsage: primary, usagePairs: pairs,
                                    maxInputReportSize: intProperty(device, kIOHIDMaxInputReportSizeKey),
                                    maxOutputReportSize: intProperty(device, kIOHIDMaxOutputReportSizeKey),
                                    isFollowerCandidate: primary == target || pairs.contains(target))
        }
        return HidOverview(totalDevices: devices.count, logitech: logitech)
    }

    func accessStatus() -> String {
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if access == kIOHIDAccessTypeGranted { return "inputMonitoring=granted" }
        if access == kIOHIDAccessTypeDenied { return "inputMonitoring=denied" }
        return "inputMonitoring=unknown"
    }

    private func candidates() -> [(IOHIDDevice, DiscoveredFollower)] {
        return allDevices().compactMap { device in
            guard intProperty(device, kIOHIDVendorIDKey) == HidKeys.vendor, let product = intProperty(device, kIOHIDProductIDKey) else { return nil }
            let primary = intProperty(device, kIOHIDPrimaryUsagePageKey) == HidKeys.usagePage && intProperty(device, kIOHIDPrimaryUsageKey) == HidKeys.usage
            let pairs = (property(device, kIOHIDDeviceUsagePairsKey) as? [[String: Any]]) ?? []
            let inPairs = pairs.contains {
                ($0[kIOHIDDeviceUsagePageKey] as? NSNumber)?.intValue == HidKeys.usagePage && ($0[kIOHIDDeviceUsageKey] as? NSNumber)?.intValue == HidKeys.usage
            }
            guard primary || inPairs else { return nil }
            var hash: String?
            var source = "none"
            for key in HidKeys.identityKeys {
                guard let value = property(device, key).map({ "\($0)" }), !value.isEmpty else { continue }
                hash = SHA256.hash(data: Data("\(key):\(value)".utf8)).map { String(format: "%02x", $0) }.joined()
                source = key
                break
            }
            // Facts for diagnosis only. Identifier values themselves are never reported.
            let platform: [String: String] = [
                "product": (property(device, kIOHIDProductKey) as? String) ?? "",
                "transport": (property(device, kIOHIDTransportKey) as? String) ?? "",
                "collectionMatch": primary ? "primary" : "usagePairs",
                "usagePairCount": String(pairs.count),
                "maxInputReportSize": intProperty(device, kIOHIDMaxInputReportSizeKey).map(String.init) ?? "",
                "maxOutputReportSize": intProperty(device, kIOHIDMaxOutputReportSizeKey).map(String.init) ?? "",
                "maxFeatureReportSize": intProperty(device, kIOHIDMaxFeatureReportSizeKey).map(String.init) ?? "",
                "identitySource": source,
            ]
            return (device, DiscoveredFollower(identity: FollowerIdentity(productId: String(format: "%04X", product), identityHash: hash),
                                               platform: platform))
        }
    }

    func discover() throws -> [DiscoveredFollower] { candidates().map { $0.1 } }

    func openUnique(_ identity: FollowerIdentity) throws -> FollowerSession {
        let found = candidates()
        let index = try FollowerSelection.unique(found.map { $0.1.identity }, for: identity)
        return HidppSession(transport: try IOKitHidppTransport(device: found[index].0, clock: clock), clock: clock)
    }
}

/// Shared (non-seizing) access to one device. Reports arrive through the current run loop.
final class IOKitHidppTransport: HidppTransport {
    private let device: IOHIDDevice
    private let clock: MonotonicClock
    private let bufferSize = 64
    private let buffer: UnsafeMutablePointer<UInt8>
    private var queue: [[UInt8]] = []
    private var removed = false
    private var open = false

    init(device: IOHIDDevice, clock: MonotonicClock) throws {
        self.device = device
        self.clock = clock
        buffer = .allocate(capacity: bufferSize)
        buffer.initialize(repeating: 0, count: bufferSize)
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            buffer.deallocate()
            if result == IOKitReturn.notPermitted || result == IOKitReturn.notPrivileged { throw LocatorError.accessDenied(native: result) }
            throw HidppError.io(native: result)
        }
        open = true
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, bufferSize, { context, _, _, _, reportId, report, length in
            guard let context else { return }
            Unmanaged<IOKitHidppTransport>.fromOpaque(context).takeUnretainedValue().receive(reportId: reportId, report: report, length: length)
        }, context)
        IOHIDDeviceRegisterRemovalCallback(device, { context, _, _ in
            guard let context else { return }
            Unmanaged<IOKitHidppTransport>.fromOpaque(context).takeUnretainedValue().removed = true
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    private func receive(reportId: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        // Accept HID++ long reports whether or not IOKit includes the report ID byte. Ignore pointer/key reports.
        let bytes = Array(UnsafeBufferPointer(start: report, count: max(0, length)))
        if bytes.count == HidppPackets.reportLength && bytes[0] == 0x11 { queue.append(bytes) }
        else if bytes.count == HidppPackets.reportLength - 1 && reportId == 0x11 { queue.append([0x11] + bytes) }
    }

    func write(_ report: [UInt8], timeoutMs: Int64) throws {
        guard open else { throw HidppError.disconnected }
        if removed { throw HidppError.disconnected }
        // With a non-zero report ID, the buffer includes it (the hidapi convention on macOS).
        let result = report.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(report[0]), $0.baseAddress!, $0.count)
        }
        switch result {
        case kIOReturnSuccess: return
        case IOKitReturn.notAttached, IOKitReturn.noDevice: removed = true; throw HidppError.disconnected
        case IOKitReturn.timeout: throw HidppError.timeout
        default: throw HidppError.io(native: result)
        }
    }

    func read(timeoutMs: Int64) throws -> [UInt8] {
        let deadline = clock.monotonicMs + timeoutMs
        while true {
            if !queue.isEmpty { return queue.removeFirst() }
            if removed { throw HidppError.disconnected }
            let remaining = deadline - clock.monotonicMs
            guard remaining > 0 else { throw HidppError.timeout }
            if CFRunLoopRunInMode(.defaultMode, Double(remaining) / 1000, true) == .finished {
                usleep(useconds_t(min(remaining, 10) * 1000))
            }
        }
    }

    func close() {
        guard open else { return }
        open = false
        IOHIDDeviceRegisterInputReportCallback(device, buffer, bufferSize, nil, nil)
        IOHIDDeviceRegisterRemovalCallback(device, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        buffer.deallocate()
    }

    deinit { close() }
}
#endif
