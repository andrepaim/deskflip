// swift-tools-version:5.9
import PackageDescription

// The core library is pure Swift and builds/tests on Windows and macOS.
// IOKit, m1ddc, file locking and signing live in the executable and are macOS-only.
let package = Package(
    name: "MonitorSwitchMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "monitor-switch-mac", targets: ["monitor-switch-mac"]),
    ],
    targets: [
        .target(name: "MonitorSwitchMacCore"),
        .executableTarget(name: "monitor-switch-mac", dependencies: ["MonitorSwitchMacCore"]),
        .testTarget(name: "MonitorSwitchMacCoreTests", dependencies: ["MonitorSwitchMacCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
