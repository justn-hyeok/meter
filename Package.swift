// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Meter",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Meter", targets: ["Meter"])],
    targets: [
        .executableTarget(name: "Meter"),
        .testTarget(name: "MeterTests", dependencies: ["Meter"], resources: [.process("Fixtures")]),
    ]
)
