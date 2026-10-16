// swift-tools-version: 5.9

import PackageDescription
import Foundation

// SwiftPM identifies a local path dependency from its checkout directory.
// Derive that identity so the fixture also works when the repository is
// cloned under a different directory name.
let repositoryName = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .lastPathComponent

let package = Package(
    name: "PackageConsumer",
    platforms: [
        .macOS(.v12)
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "PackageConsumer",
            dependencies: [
                .product(name: "GraphEvo", package: repositoryName)
            ]
        )
    ]
)
