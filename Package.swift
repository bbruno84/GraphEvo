// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "GraphEvo",
    platforms: [
        .iOS(.v16), .macOS(.v12) // opzionale macOS se ti serve
    ],
    products: [
        .library(name: "GraphEvo", targets: ["GraphEvo"])
        // .library(name: "GraphEvoMigration", targets: ["GraphEvoMigration"]) // se lo separi
    ], dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.0")
    ],
    targets: [
        .target(
            name: "GraphEvo",
            dependencies: ["ZIPFoundation"],
            path: "Sources/GraphEvo",
            swiftSettings: [
                .define("GRAPHEVO_IOS16")
            ]
        ),
        // .target(
        //     name: "GraphEvoMigration",
        //     dependencies: ["GraphEvo"],
        //     path: "Sources/GraphEvoMigration"
        // ),
        .testTarget(
            name: "GraphEvoTests",
            dependencies: ["GraphEvo", "ZIPFoundation"],
            path: "Tests/GraphEvoTests",
            resources: [.process("Resources")]
        )
        // .testTarget(
        //     name: "GraphEvoMigrationTests",
        //     dependencies: ["GraphEvo", "GraphEvoMigration"],
        //     path: "Tests/GraphEvoMigrationTests"
        // )
    ]
)
