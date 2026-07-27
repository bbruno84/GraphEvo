import XCTest
@testable import GraphEvo

final class CloudKitConfigurationTests: XCTestCase {
    func testExplicitConfigurationWinsOverRuntimeAndInfoPlist() {
        var configuration = GraphStoreConfiguration()
        configuration.cloudKitContainerIdentifier = "iCloud.explicit"

        XCTAssertEqual(
            Graph.resolvedCloudKitContainerIdentifier(
                configuration: configuration,
                runtimeOverride: "iCloud.runtime",
                infoPlistValue: "iCloud.plist"
            ),
            "iCloud.explicit"
        )
    }

    func testRuntimeOverrideWinsOverInfoPlist() {
        let configuration = GraphStoreConfiguration()
        XCTAssertEqual(
            Graph.resolvedCloudKitContainerIdentifier(
                configuration: configuration,
                runtimeOverride: "iCloud.runtime",
                infoPlistValue: "iCloud.plist"
            ),
            "iCloud.runtime"
        )
    }

    func testInfoPlistIsUsedWhenNoExplicitValueExists() {
        let configuration = GraphStoreConfiguration()
        XCTAssertEqual(
            Graph.resolvedCloudKitContainerIdentifier(
                configuration: configuration,
                runtimeOverride: nil,
                infoPlistValue: " iCloud.plist "
            ),
            "iCloud.plist"
        )
    }

}
