import Foundation
import XCTest

final class UIRefreshContractTests: XCTestCase {
    func test_highFrequencyTrafficDoesNotPublishThroughVPNController() throws {
        let controller = try source("Sources/XDVPN/VPNController.swift")
        let content = try source("Sources/XDVPN/ContentView.swift")

        XCTAssertTrue(controller.contains("let trafficMonitor = TrafficMonitor()"))
        XCTAssertFalse(controller.contains("@Published private(set) var trafficIn:"))
        XCTAssertFalse(controller.contains("@Published private(set) var trafficOut:"))
        XCTAssertFalse(controller.contains("@Published private(set) var trafficInRate:"))
        XCTAssertFalse(controller.contains("@Published private(set) var trafficOutRate:"))
        XCTAssertTrue(content.contains("@ObservedObject var traffic: TrafficMonitor"))
    }

    func test_closedMainWindowReleasesHostingTreeAndStopsPreferredSizeFeedback() throws {
        let app = try source("Sources/XDVPN/XDVPNApp.swift")

        XCTAssertTrue(app.contains("hosting.sizingOptions = []"))
        XCTAssertFalse(app.contains("hosting.sizingOptions = .preferredContentSize"))
        XCTAssertTrue(app.contains("window.isReleasedWhenClosed = false"))
        XCTAssertTrue(app.contains("window.contentViewController = nil"))
        XCTAssertTrue(app.contains("mainWindow = nil"))
    }

    func test_statusItemRefreshUsesOneDeduplicatedTrafficSnapshot() throws {
        let app = try source("Sources/XDVPN/XDVPNApp.swift")

        XCTAssertTrue(app.contains("controller.trafficMonitor.$snapshot"))
        XCTAssertTrue(app.contains(".removeDuplicates()"))
        XCTAssertFalse(app.contains("Publishers.CombineLatest(controller.$trafficInRate"))
        XCTAssertTrue(app.contains("guard presentation != lastStatusItemPresentation else { return }"))
    }

    private func source(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
