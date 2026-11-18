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
        .executable(name: "rookeryctl", targets: ["rookeryctl"]),
        .executable(name: "rookery-chrome-host", targets: ["RookeryChromeHost"]),
        .executable(name: "rookery-mail", targets: ["RookeryMail"]),
        .executable(name: "rookery-brand", targets: ["RookeryBrand"]),
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
            name: "rookeryctl",
            dependencies: ["RookeryCore", "RookeryControl"],
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "RookeryMail",
            dependencies: ["RookeryCore", "RookeryControl"],
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "RookeryBrand",
            dependencies: ["RookeryCore"],
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
