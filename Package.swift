// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "mull",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0"),
    ],
    targets: [
        .executableTarget(
            name: "mull",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "mull",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "MullTests",
            dependencies: [
                "mull",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests"
        ),
    ]
)
