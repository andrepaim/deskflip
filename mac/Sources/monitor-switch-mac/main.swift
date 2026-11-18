import Foundation
import MonitorSwitchMacCore

#if os(macOS)
let app = App(store: FileAppStore(), lock: FileOperationLock(), locator: IOKitFollowerLocator(clock: SystemClock()),
              tools: ProcessToolRunner(), clock: SystemClock(), processId: ProcessInfo.processInfo.processIdentifier,
              console: { print($0) })
let bundleCommand = Bundle.main.object(forInfoDictionaryKey: "MonitorSwitchCommand") as? String
exit(app.run(CommandLineParser.launchArguments(Array(CommandLine.arguments.dropFirst()), bundleCommand: bundleCommand)))
#else
// The core library builds and tests on other platforms; the helper itself is macOS-only.
FileHandle.standardError.write(Data("monitor-switch-mac runs only on macOS.\n".utf8))
exit(ExitCodes.unsupported)
#endif
