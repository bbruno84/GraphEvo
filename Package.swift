// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "GraphCK",
    platforms: [
        .iOS(.v16), .macOS(.v12) // opzionale macOS se ti serve
    ],
    products: [
        .library(name: "GraphCK", targets: ["GraphCK"])
        // .library(name: "GraphCKMigration", targets: ["GraphCKMigration"]) // se lo separi
    ], dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.0")
    ],
    targets: [
        .target(
            name: "GraphCK",
            dependencies: ["ZIPFoundation"],
            path: "Sources/GraphCK",
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
            name: "GraphCKTests",
            dependencies: ["GraphCK", "ZIPFoundation"],
            path: "Tests/GraphCKTests",
            resources: [.process("Resources")]
        )
        // .testTarget(
        //     name: "GraphCKMigrationTests",
        //     dependencies: ["GraphCK", "GraphCKMigration"],
        //     path: "Tests/GraphCKMigrationTests"
        // )
    ]
)
