// swift-tools-version: 6.0

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

var modelConsumerSettings: [SwiftSetting] = [.swiftLanguageMode(.v6)]
#if compiler(>=6.1)
modelConsumerSettings.append(.enableUpcomingFeature("MemberImportVisibility"))
#endif

let package = Package(
    name: "PackageConsumer",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "PackageConsumer",
            dependencies: [
                .product(name: "GraphEvo", package: repositoryName)
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ProcessConsumer",
            dependencies: [.product(name: "GraphEvo", package: repositoryName)],
            swiftSettings: modelConsumerSettings
        ),
        .executableTarget(
            name: "ModelConsumer",
            dependencies: [.product(name: "GraphEvo", package: repositoryName)],
            swiftSettings: modelConsumerSettings
        )
    ]
)
