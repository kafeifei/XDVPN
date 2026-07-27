import XCTest
@testable import XDVPNCore

final class WiFiOnDemandPolicyTests: XCTestCase {
    func test_disabledPolicyDoesNotMatch() {
        let policy = WiFiOnDemandPolicy(
            isEnabled: false,
            rules: [WiFiOnDemandRule(ssid: "Office", action: .disconnectVPN)]
        )

        XCTAssertEqual(policy.decision(for: "Office"), .noMatch)
    }

    func test_connectRuleMatchesExactSSID() {
        let policy = WiFiOnDemandPolicy(
            isEnabled: true,
            rules: [WiFiOnDemandRule(ssid: "Home", action: .connectVPN)]
        )

        XCTAssertEqual(policy.decision(for: "Home"), .connect)
    }

    func test_disconnectRuleMatchesExactSSID() {
        let policy = WiFiOnDemandPolicy(
            isEnabled: true,
            rules: [WiFiOnDemandRule(ssid: "Office", action: .disconnectVPN)]
        )

        XCTAssertEqual(policy.decision(for: "Office"), .disconnect)
    }

    func test_unknownOrEmptySSIDDoesNotMatch() {
        let policy = WiFiOnDemandPolicy(
            isEnabled: true,
            rules: [WiFiOnDemandRule(ssid: "Office", action: .disconnectVPN)]
        )

        XCTAssertEqual(policy.decision(for: "Cafe"), .noMatch)
        XCTAssertEqual(policy.decision(for: nil), .noMatch)
        XCTAssertEqual(policy.decision(for: "  "), .noMatch)
    }

    func test_ssidMatchingIsCaseSensitive() {
        let policy = WiFiOnDemandPolicy(
            isEnabled: true,
            rules: [WiFiOnDemandRule(ssid: "Office", action: .disconnectVPN)]
        )

        XCTAssertEqual(policy.decision(for: "office"), .noMatch)
    }

    func test_replacingOrAppendingUpdatesExistingRule() {
        let original = [WiFiOnDemandRule(ssid: "Office", action: .disconnectVPN)]
        let updated = WiFiOnDemandPolicy.replacingOrAppending(
            original,
            ssid: "Office",
            action: .connectVPN
        )

        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated[0].ssid, "Office")
        XCTAssertEqual(updated[0].action, .connectVPN)
    }

    func test_replacingOrAppendingTrimsAndAppendsSSID() {
        let updated = WiFiOnDemandPolicy.replacingOrAppending(
            [],
            ssid: "  Office  ",
            action: .disconnectVPN
        )

        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated[0].ssid, "Office")
        XCTAssertEqual(updated[0].action, .disconnectVPN)
    }
}
