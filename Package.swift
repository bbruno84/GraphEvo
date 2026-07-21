// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Graph",
    platforms: [
        .iOS(.v16), .macOS(.v12) // opzionale macOS se ti serve
    ],
    products: [
        // Keep the original product name for source compatibility and expose
        // the GraphCK name used by the demo and the fork's documentation.
        .library(name: "Graph", targets: ["Graph"]),
        .library(name: "GraphCK", targets: ["Graph"])
        // .library(name: "GraphCKMigration", targets: ["GraphCKMigration"]) // se lo separi
    ], dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.0")
    ],
    targets: [
        .target(
            name: "Graph",
            dependencies: ["ZIPFoundation"],
            path: "Sources/Graph",
            swiftSettings: [
                .define("GRAPHCK_IOS16"),
                .unsafeFlags(["-Xfrontend", "-strict-concurrency=targeted"])// se vuoi eventuali #if
            ]
        ),
        // .target(
        //     name: "GraphCKMigration",
        //     dependencies: ["GraphCK"],
        //     path: "Sources/GraphCKMigration"
        // ),
        .testTarget(
            name: "GraphTests",
            dependencies: ["Graph", "ZIPFoundation"],
            path: "Tests/GraphTests",
            resources: [.process("Resources")]
        )
        // .testTarget(
        //     name: "GraphCKMigrationTests",
        //     dependencies: ["GraphCK", "GraphCKMigration"],
        //     path: "Tests/GraphCKMigrationTests"
        // )
    ]
)
