// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Dream",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0"),
    ],
    targets: [
        .executableTarget(
            name: "Dream",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Dream",
            resources: [
                .process("Resources")
            ]
        ),
    ]
)
