// swift-tools-version: 6.0
import PackageDescription
import Foundation

let repositoryName = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
let package = Package(name: "ConsolidationCosts", platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../..")],
    targets: [.executableTarget(name: "CostProbe", dependencies: [.product(name: "GraphEvo", package: repositoryName)],
        swiftSettings: [.swiftLanguageMode(.v6)])])
