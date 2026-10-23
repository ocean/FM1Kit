// swift-tools-version: 6.1
import PackageDescription

/// Compiler settings shared by every target: Swift 6 language mode plus upcoming features that
/// make dependencies, existentials and imports explicit.
let strictSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "FM1Kit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FM1Kit", targets: ["FM1Kit"]),
        // macOS only: the chip's USB download mode needs root to take the FM-1 from macOS's disk
        // driver, which iOS apps can't do. On iOS the library is empty.
        .library(name: "FM1Rescue", targets: ["FM1Rescue"]),
        .executable(name: "fm1probe", targets: ["fm1probe"]),
    ],
    targets: [
        .target(name: "FM1Kit", swiftSettings: strictSettings),
        .target(
            name: "FM1Rescue",
            dependencies: ["FM1Kit"],
            resources: [
                .copy("Resources/mflr-loader-a.bin"), .copy("Resources/mflr-loader-b.bin"),
                .copy("Resources/NOTICE.md"),
            ],
            swiftSettings: strictSettings,
            linkerSettings: [.linkedFramework("IOUSBHost", .when(platforms: [.macOS]))]
        ),
        .executableTarget(name: "fm1probe", dependencies: ["FM1Kit", "FM1Rescue"], swiftSettings: strictSettings),
        .testTarget(name: "FM1KitTests", dependencies: ["FM1Kit"], swiftSettings: strictSettings),
        .testTarget(name: "FM1RescueTests", dependencies: ["FM1Rescue", "FM1Kit"], swiftSettings: strictSettings),
    ],
    swiftLanguageModes: [.v6]
)
