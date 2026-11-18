// swift-tools-version:5.9
import PackageDescription

// The core library is pure Swift and builds/tests on Windows and macOS.
// IOKit, m1ddc, file locking and signing live in the executable and are macOS-only.
let package = Package(
    name: "Deskflip",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "deskflip-mac", targets: ["deskflip-mac"]),
    ],
    targets: [
        .target(name: "DeskflipCore"),
        .executableTarget(name: "deskflip-mac", dependencies: ["DeskflipCore"]),
        .testTarget(name: "DeskflipCoreTests", dependencies: ["DeskflipCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
