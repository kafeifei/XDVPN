import XCTest
@testable import XDVPNCore

final class RouteOwnershipTrackerTests: XCTestCase {
    func test_failedInstallIsNotOwnedAndCanBeRetried() {
        var tracker = RouteOwnershipTracker<String>()

        XCTAssertEqual(
            tracker.installIfNeeded("203.0.113.4", install: { false }),
            .failed
        )
        XCTAssertTrue(tracker.ownedRoutes.isEmpty)
        XCTAssertEqual(
            tracker.installIfNeeded("203.0.113.4", install: { true }),
            .installed
        )
        XCTAssertEqual(tracker.ownedRoutes, ["203.0.113.4"])
    }

    func test_ownedRouteIsNotInstalledTwice() {
        var tracker = RouteOwnershipTracker<String>()
        var installCount = 0
        let install = {
            installCount += 1
            return true
        }

        XCTAssertEqual(tracker.installIfNeeded("203.0.113.4", install: install), .installed)
        XCTAssertEqual(tracker.installIfNeeded("203.0.113.4", install: install), .alreadyOwned)
        XCTAssertEqual(installCount, 1)
    }
}
