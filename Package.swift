// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FM1Kit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FM1Kit", targets: ["FM1Kit"]),
        .executable(name: "fm1probe", targets: ["fm1probe"]),
    ],
    targets: [
        .target(name: "FM1Kit"),
        .executableTarget(name: "fm1probe", dependencies: ["FM1Kit"]),
        .testTarget(name: "FM1KitTests", dependencies: ["FM1Kit"]),
    ]
)
