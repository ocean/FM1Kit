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
        .executable(name: "fm1probe", targets: ["fm1probe"]),
    ],
    targets: [
        .target(name: "FM1Kit", swiftSettings: strictSettings),
        .executableTarget(name: "fm1probe", dependencies: ["FM1Kit"], swiftSettings: strictSettings),
        .testTarget(name: "FM1KitTests", dependencies: ["FM1Kit"], swiftSettings: strictSettings),
    ],
    swiftLanguageModes: [.v6]
)
