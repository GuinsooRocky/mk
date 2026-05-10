// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WE",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "MK",
            path: "Sources",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
