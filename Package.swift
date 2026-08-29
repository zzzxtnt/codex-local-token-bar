// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexTokenBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CodexTokenBar", targets: ["CodexTokenBar"])
    ],
    targets: [
        .executableTarget(
            name: "CodexTokenBar",
            path: "Sources/CodexTokenBar"
        ),
        .testTarget(
            name: "CodexTokenBarTests",
            dependencies: ["CodexTokenBar"],
            path: "Tests/CodexTokenBarTests"
        )
    ]
)
