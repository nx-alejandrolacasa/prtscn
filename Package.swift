// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PrtScn",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PrtScn",
            path: "Sources/PrtScn"
        )
    ]
)
