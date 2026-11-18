import Foundation

public struct MonitorConfig: Equatable, Codable {
    public var m1ddcPath: String
    // The Samsung's identifier from `m1ddc display list`, chosen by the owner. Never "first" or list order.
    public var displayId: String
    public init(m1ddcPath: String, displayId: String) { self.m1ddcPath = m1ddcPath; self.displayId = displayId }
}

public struct MacConfig: Equatable, Codable {
    public var schemaVersion: Int
    public var monitor: MonitorConfig
    public var devices: [FollowerConfig]
    public init(schemaVersion: Int = 1, monitor: MonitorConfig, devices: [FollowerConfig]) {
        self.schemaVersion = schemaVersion; self.monitor = monitor; self.devices = devices
    }
}

public struct ConfigError: Error, Equatable, CustomStringConvertible {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var description: String { reason }
}

public enum ConfigParser {
    private static let rootKeys: Set<String> = ["schemaVersion", "monitor", "devices"]
    private static let monitorKeys: Set<String> = ["m1ddcPath", "displayId"]
    private static let deviceKeys: Set<String> = ["name", "productId", "identityHash", "targetChannel", "targetHostName"]

    public static func parse(_ text: String) throws -> MacConfig {
        let data = Data(text.utf8)
        // Unknown fields are rejected, as on Windows. Codable alone would ignore them.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConfigError("Config is not a JSON object.") }
        try requireKeys(root, rootKeys, "config")
        guard let monitor = root["monitor"] as? [String: Any] else { throw ConfigError("monitor must be an object.") }
        try requireKeys(monitor, monitorKeys, "monitor")
        guard let devices = root["devices"] as? [Any] else { throw ConfigError("devices must be an array.") }
        for device in devices {
            guard let object = device as? [String: Any] else { throw ConfigError("Each device must be an object.") }
            try requireKeys(object, deviceKeys, "device", optional: ["identityHash"])
        }
        let config: MacConfig
        do { config = try JSONDecoder().decode(MacConfig.self, from: data) }
        catch { throw ConfigError("Config fields have invalid types.") }
        try validate(config)
        return config
    }

    private static func requireKeys(_ object: [String: Any], _ allowed: Set<String>, _ scope: String, optional: Set<String> = []) throws {
        let keys = Set(object.keys)
        if let unknown = keys.subtracting(allowed).sorted().first { throw ConfigError("Unknown \(scope) field: \(unknown).") }
        if let missing = allowed.subtracting(optional).subtracting(keys).sorted().first { throw ConfigError("Missing \(scope) field: \(missing).") }
    }

    public static func validate(_ config: MacConfig) throws {
        guard config.schemaVersion == 1 else { throw ConfigError("schemaVersion must be 1.") }
        let path = config.monitor.m1ddcPath
        guard path.hasPrefix("/"), !isPlaceholder(path), !path.contains(".."), path.count <= 1024 else {
            throw ConfigError("m1ddcPath must be an absolute path.")
        }
        guard isDisplayId(config.monitor.displayId) else { throw ConfigError("displayId is missing or a placeholder.") }
        guard (1...4).contains(config.devices.count) else { throw ConfigError("One to four devices are required.") }
        var names = Set<String>(), identities = Set<FollowerIdentity>()
        for device in config.devices {
            guard isName(device.name), names.insert(device.name.lowercased()).inserted,
                  isProductId(device.productId),
                  device.identityHash.map(isHash) ?? true,
                  (1...3).contains(device.targetChannel),
                  isHostName(device.targetHostName),
                  identities.insert(device.identity).inserted
            else { throw ConfigError("Invalid or duplicate device enrollment.") }
        }
        // A hash-less enrollment matches any device of that product; it cannot coexist with another of the same product.
        let products = config.devices.map { $0.productId.uppercased() }
        guard Set(products).count == products.count else { throw ConfigError("Each product may be enrolled once.") }
    }

    public static func isName(_ value: String) -> Bool {
        (1...64).contains(value.count) && value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
    }
    public static func isProductId(_ value: String) -> Bool {
        value.count == 4 && value.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }
    }
    public static func isHash(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdef").contains($0) }
    }
    public static func isHostName(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespaces).isEmpty && !isPlaceholder(value) && value.count <= 255
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    public static func isDisplayId(_ value: String) -> Bool {
        (1...128).contains(value.count) && !isPlaceholder(value)
            && value.unicodeScalars.allSatisfy { $0.isASCII && !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }
    }
    private static func isPlaceholder(_ value: String) -> Bool { value.contains("<") || value.contains(">") }

    public static func encode(_ config: MacConfig) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(config), as: UTF8.self) + "\n"
    }
}
