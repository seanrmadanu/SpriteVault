// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FortniteSpriteTracker",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FortniteSpriteTracker", targets: ["FortniteSpriteTracker"])
    ],
    targets: [
        .executableTarget(
            name: "FortniteSpriteTracker",
            path: "Sources/FortniteSpriteTracker",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
