// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "oomguard",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "oomguard", targets: ["oomguard"]),
    ],
    targets: [
        .target(name: "OOMGuardCore"),
        .executableTarget(name: "oomguard", dependencies: ["OOMGuardCore"]),
        .testTarget(name: "OOMGuardCoreTests", dependencies: ["OOMGuardCore"]),
    ],
    swiftLanguageModes: [.v5]
)
