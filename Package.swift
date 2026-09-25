// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PrtScn",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "PrtScn",
            path: "Sources/PrtScn"
        ),
        .testTarget(
            name: "PrtScnTests",
            dependencies: ["PrtScn"],
            path: "Tests/PrtScnTests"
        ),
    ]
)
