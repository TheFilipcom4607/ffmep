// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ffmep",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ffmep", targets: ["ffmep"])
    ],
    targets: [
        .executableTarget(
            name: "ffmep",
            path: "Sources/ffmep",
            // Packaged into ffmep.app by scripts/make-app.sh, not SwiftPM resources.
            exclude: ["Resources"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ffmepTests",
            dependencies: ["ffmep"],
            path: "Tests/ffmepTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
