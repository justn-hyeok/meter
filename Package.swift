// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Meter",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MeterCore", targets: ["MeterCore"]),
        .executable(name: "MeterApp", targets: ["MeterApp"]),
        .executable(name: "meter", targets: ["MeterCLI"]),
    ],
    targets: [
        .target(name: "MeterCore"),
        .executableTarget(name: "MeterApp", dependencies: ["MeterCore"]),
        .executableTarget(name: "MeterCLI", dependencies: ["MeterCore"]),
        .testTarget(
            name: "MeterTests",
            dependencies: ["MeterCore", "MeterCLI"],
            resources: [.process("Fixtures")]
        ),
    ]
)
