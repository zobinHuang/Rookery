// swift-tools-version: 6.2
import PackageDescription

let strictSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "MuxShots",
    platforms: [
        .macOS("14.2"),
    ],
    products: [
        .executable(name: "MuxShots", targets: ["MuxShots"]),
        .executable(name: "muxctl", targets: ["muxctl"]),
        .executable(name: "muxshots-chrome-host", targets: ["MuxShotsChromeHost"]),
    ],
    targets: [
        .target(
            name: "MuxShotsCore",
            swiftSettings: strictSettings
        ),
        .target(
            name: "MuxShotsPlatform",
            dependencies: ["MuxShotsCore"],
            swiftSettings: strictSettings
        ),
        .target(
            name: "MuxShotsControl",
            dependencies: ["MuxShotsCore"],
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "MuxShots",
            dependencies: ["MuxShotsCore", "MuxShotsPlatform", "MuxShotsControl"],
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "muxctl",
            dependencies: ["MuxShotsCore", "MuxShotsControl"],
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "MuxShotsChromeHost",
            dependencies: ["MuxShotsControl"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "MuxShotsCoreTests",
            dependencies: ["MuxShotsCore", "MuxShotsControl"],
            swiftSettings: strictSettings
        ),
    ]
)
