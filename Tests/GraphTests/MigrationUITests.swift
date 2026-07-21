import XCTest
@testable import Graph

final class MigrationUITests: XCTestCase {
    func testProgressNotificationIsParsedAndDelivered() {
        let expectation = expectation(description: "migration progress")
        let storeURL = URL(fileURLWithPath: "/tmp/GraphCK-progress.sqlite")
        var received: GraphMigrationManager.ProgressInfo?
        let observer = GraphMigrationManager.observeMigrationProgress { info in
            received = info
            expectation.fulfill()
        }
        defer { GraphMigrationManager.removeProgressObserver(observer) }

        GraphMigrationManager.postMigrationProgress(
            storeURL: storeURL,
            phase: .ready,
            progress: 0.75,
            stepDescription: "Testing",
            status: "running"
        )

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(received?.storeURL, storeURL)
        guard case .ready? = received?.phase else {
            XCTFail("Progress phase should be ready")
            return
        }
        XCTAssertEqual(received?.progress, 0.75)
        XCTAssertEqual(received?.stepDescription, "Testing")
        XCTAssertEqual(received?.status, "running")
    }

    func testMalformedProgressNotificationIsRejected() {
        let notification = Notification(
            name: .GraphMigrationProgressDidChange,
            userInfo: [GraphMigrationManager.ProgressKey.progress.rawValue: 0.5]
        )
        XCTAssertNil(GraphMigrationManager.parseProgress(from: notification))
    }
}
