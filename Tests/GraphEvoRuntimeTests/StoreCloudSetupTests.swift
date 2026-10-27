import Testing
@testable import GraphEvoRuntime

@Suite struct StoreCloudSetupTests {
    @Test func setupRequiresEveryStoreAndRetainsPayloadFreeFailureDetails() {
        let tracker = StoreCloudSetupTracker()
        tracker.record("private", success: true, failure: nil)
        #expect(tracker.snapshot(configured: true, identifiers: ["private", "shared"]).readyStoreCount == 1)
        tracker.record("shared", success: true, failure: nil)
        #expect(tracker.snapshot(configured: true, identifiers: ["private", "shared"]).readyStoreCount == 2)
        tracker.record("shared", success: false, failure: ("SyntheticError", 42))
        let failed = tracker.snapshot(configured: true, identifiers: ["private", "shared"])
        #expect(failed.readyStoreCount == 1)
        #expect(failed.latestFailureDomain == "SyntheticError")
        #expect(failed.latestFailureCode == 42)
        tracker.record("shared", success: true, failure: nil)
        #expect(tracker.snapshot(configured: true, identifiers: ["private", "shared"]).readyStoreCount == 2)
    }
}
