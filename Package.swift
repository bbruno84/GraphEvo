// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "GraphEvo",
    platforms: [
        .iOS(.v16), .macOS(.v13)
    ],
    products: [
        .library(name: "GraphEvo", targets: ["GraphEvo"])
        // .library(name: "GraphEvoMigration", targets: ["GraphEvoMigration"]) // se lo separi
    ],
    targets: [
        .executableTarget(
            name: "ObservationCostProbe",
            dependencies: ["GraphEvo"],
            path: "Experiments/SharedObservation/Sources",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "IdentityLookupProbe",
            dependencies: ["GraphEvo"],
            path: "Experiments/IdentityLookup/Sources",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "GraphEvo",
            dependencies: ["GraphEvoRuntime", "GraphEvoModel", "GraphEvoStore"],
            path: "Sources/GraphEvo",
            swiftSettings: [
                .define("GRAPHEVO_IOS16"),
                .swiftLanguageMode(.v5)
            ]
        ),
        .target(
            name: "GraphEvoStore",
            dependencies: ["GraphEvoModel", "GraphEvoRuntime"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GraphEvoStoreTests",
            dependencies: ["GraphEvo", "GraphEvoStore", "GraphEvoRuntime"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "GraphEvoModel",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GraphEvoModelTests",
            dependencies: ["GraphEvoModel", "GraphEvo", "GraphEvoRuntime"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "GraphEvoRuntime",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GraphEvoRuntimeTests",
            dependencies: ["GraphEvoRuntime", "GraphEvo"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // .target(
        //     name: "GraphEvoMigration",
        //     dependencies: ["GraphEvo"],
        //     path: "Sources/GraphEvoMigration"
        // ),
        .testTarget(
            name: "GraphEvoTests",
            dependencies: ["GraphEvo"],
            path: "Tests/GraphEvoTests",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
        // .testTarget(
        //     name: "GraphEvoMigrationTests",
        //     dependencies: ["GraphEvo", "GraphEvoMigration"],
        //     path: "Tests/GraphEvoMigrationTests"
        // )
    ]
)
