#if os(macOS)
import Darwin
import Foundation
import MonitorSwitchMacCore

final class SystemClock: MonotonicClock {
    var monotonicMs: Int64 { Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1_000_000) }
    var wallClockMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    func delay(ms: Int64) {
        // Pump the run loop so IOKit removal callbacks are delivered while waiting.
        guard ms > 0 else { return }
        // With no sources scheduled the run loop returns at once, so fall back to sleeping.
        if CFRunLoopRunInMode(.defaultMode, Double(ms) / 1000, false) == .finished { usleep(useconds_t(ms * 1000)) }
    }
}

enum AppPaths {
    static let root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MonitorSwitch", isDirectory: true)
    static var config: URL { root.appendingPathComponent("config.json") }
    static var previousConfig: URL { root.appendingPathComponent("config.previous.json") }
    static var lastResult: URL { root.appendingPathComponent("last-result.json") }
    static var lock: URL { root.appendingPathComponent("operation.lock") }
    static var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }

    static func ensure() throws {
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}

final class FileAppStore: AppStore {
    func readConfig() throws -> String? {
        guard FileManager.default.fileExists(atPath: AppPaths.config.path) else { return nil }
        return try String(contentsOf: AppPaths.config, encoding: .utf8)
    }

    func writeConfig(_ text: String) throws {
        try AppPaths.ensure()
        if FileManager.default.fileExists(atPath: AppPaths.config.path) {
            try? FileManager.default.removeItem(at: AppPaths.previousConfig)
            try FileManager.default.copyItem(at: AppPaths.config, to: AppPaths.previousConfig)
        }
        try Data(text.utf8).write(to: AppPaths.config, options: .atomic)
    }

    func readLastResult() -> String? { try? String(contentsOf: AppPaths.lastResult, encoding: .utf8) }

    func writeLastResult(_ text: String) throws {
        try AppPaths.ensure()
        try Data(text.utf8).write(to: AppPaths.lastResult, options: .atomic)
    }

    func appendLog(_ line: String) throws { try append(line, to: "monitor-switch-\(day()).jsonl") }
    func appendProbe(_ line: String) throws { try append(line, to: "trigger-probe-\(day()).jsonl") }

    private func day() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func append(_ line: String, to name: String) throws {
        try AppPaths.ensure()
        let url = AppPaths.logs.appendingPathComponent(name)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(fd) }
        let bytes = Array((line + "\n").utf8)
        guard bytes.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == bytes.count else { throw CocoaError(.fileWriteUnknown) }
        fsync(fd)
    }
}

final class FileLease: LockLease {
    private var fd: Int32
    init(fd: Int32) { self.fd = fd }
    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        Darwin.close(fd)
        fd = -1
    }
    deinit { release() }
}

final class FileOperationLock: OperationLock {
    func tryAcquire() -> LockLease? {
        guard (try? AppPaths.ensure()) != nil else { return nil }
        let fd = open(AppPaths.lock.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); return nil }
        return FileLease(fd: fd)
    }
}

final class ProcessToolRunner: ToolRunner {
    func run(executable: String, arguments: [String], timeoutMs: Int64) -> ToolOutput {
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            return ToolOutput(exitStatus: nil, output: "Not an executable file: \(executable)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return ToolOutput(exitStatus: nil, output: "Launch failed.") }
        // Read concurrently so a full pipe cannot block the tool.
        var data = Data()
        let reader = DispatchQueue(label: "tool-output")
        let readDone = DispatchSemaphore(value: 0)
        reader.async { data = pipe.fileHandleForReading.readDataToEndOfFile(); readDone.signal() }
        if done.wait(timeout: .now() + .milliseconds(Int(timeoutMs))) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 2)
            _ = readDone.wait(timeout: .now() + 1)
            return ToolOutput(exitStatus: nil, timedOut: true, output: String(decoding: data, as: UTF8.self))
        }
        _ = readDone.wait(timeout: .now() + 2)
        // A signal-terminated tool has no exit status; never mistake its signal number for one.
        let status: Int32? = process.terminationReason == .exit ? process.terminationStatus : nil
        return ToolOutput(exitStatus: status, output: String(decoding: data, as: UTF8.self))
    }
}
#endif
