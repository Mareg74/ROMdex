 // swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ROMdex",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "ROMdex",
            path: "Sources/ROMdex",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
