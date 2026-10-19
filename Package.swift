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
            name: "MuxShotsPlatform",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "MuxShots",
            dependencies: ["MuxShotsPlatform"],
            swiftSettings: strictSettings
        ),
    ]
)
