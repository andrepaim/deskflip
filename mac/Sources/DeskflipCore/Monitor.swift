import Foundation

public struct ToolOutput: Equatable {
    public let exitStatus: Int32?
    public let timedOut: Bool
    public let output: String
    public init(exitStatus: Int32?, timedOut: Bool = false, output: String = "") {
        self.exitStatus = exitStatus; self.timedOut = timedOut; self.output = output
    }
    public var succeeded: Bool { exitStatus == 0 && !timedOut }
}

/// Runs a tool by absolute path with an argument array, never through a shell.
public protocol ToolRunner: AnyObject {
    func run(executable: String, arguments: [String], timeoutMs: Int64) -> ToolOutput
}

/// The fixed monitor surface: list displays, and set VCP 0x60 to 5 on one named display. Nothing else.
public enum M1ddc {
    public static let pcInput = 5
    public static let listArguments = ["display", "list"]

    public static func switchToPCArguments(displayId: String) throws -> [String] {
        guard ConfigParser.isDisplayId(displayId) else { throw ConfigError("Invalid display identifier.") }
        return ["display", displayId, "set", "input", String(pcInput)]
    }

    /// How many listed displays carry this identifier as a whole token. Exactly one is required.
    public static func countMatches(listOutput: String, displayId: String) -> Int {
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "[](),:"))
        return listOutput.split(whereSeparator: \.isNewline).filter { line in
            String(line).components(separatedBy: separators).contains(displayId)
        }.count
    }
}

public struct MonitorRecord: Equatable, Codable {
    public var attempted: Bool
    public var accepted: Bool
    public var exitStatus: Int32?
    public var timedOut: Bool
    public init(attempted: Bool = false, accepted: Bool = false, exitStatus: Int32? = nil, timedOut: Bool = false) {
        self.attempted = attempted; self.accepted = accepted; self.exitStatus = exitStatus; self.timedOut = timedOut
    }
}
