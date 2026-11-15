// swift-tools-version: 6.2
import PackageDescription

let strictSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "Rookery",
    platforms: [
        .macOS("14.2"),
    ],
    products: [
        .executable(name: "Rookery", targets: ["Rookery"]),
        .executable(name: "muxctl", targets: ["muxctl"]),
        .executable(name: "rookery-chrome-host", targets: ["RookeryChromeHost"]),
    ],
    targets: [
        .target(
            name: "RookeryCore",
            swiftSettings: strictSettings
        ),
        .target(
            name: "RookeryPlatform",
            dependencies: ["RookeryCore"],
            swiftSettings: strictSettings
        ),
        .target(
            name: "RookeryControl",
            dependencies: ["RookeryCore"],
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "Rookery",
            dependencies: ["RookeryCore", "RookeryPlatform", "RookeryControl"],
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "muxctl",
            dependencies: ["RookeryCore", "RookeryControl"],
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "RookeryChromeHost",
            dependencies: ["RookeryControl"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "RookeryCoreTests",
            dependencies: ["RookeryCore", "RookeryControl"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "RookeryPlatformTests",
            dependencies: ["RookeryPlatform"],
            swiftSettings: strictSettings
        ),
    ]
)
