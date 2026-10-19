// swift-tools-version: 6.2
import PackageDescription

let strictSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "MuxShots",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "MuxShots", targets: ["MuxShots"]),
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
        .executableTarget(
            name: "MuxShots",
            dependencies: ["MuxShotsCore", "MuxShotsPlatform"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "MuxShotsCoreTests",
            dependencies: ["MuxShotsCore"],
            swiftSettings: strictSettings
        ),
    ]
)
