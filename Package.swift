// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Groot",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // The headless, unit-testable runtime + agents. The SwiftUI app links against this.
        .library(name: "GrootKit", targets: ["GrootKit"])
    ],
    dependencies: [
        // Phase 0 is intentionally dependency-free so it builds offline.
        // Production persistence will add GRDB.swift here:
        // .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0")
    ],
    targets: [
        .target(
            name: "GrootKit",
            dependencies: [],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "GrootKitTests",
            dependencies: ["GrootKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
