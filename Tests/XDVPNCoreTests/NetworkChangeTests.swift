import XCTest
@testable import XDVPNCore

final class NetworkChangeTests: XCTestCase {

    func test_fingerprint_dropsUtunAndSorts() {
        XCTAssertEqual(physicalInterfaceFingerprint(["en1", "utun4", "en0"]), "en0,en1")
        XCTAssertEqual(physicalInterfaceFingerprint(["utun4", "utun7"]), "")
        XCTAssertEqual(physicalInterfaceFingerprint([]), "")
    }

    func test_fingerprint_dedupesRepeatedInterfaces() {
        // NWPath.availableInterfaces 会把同一接口报多次（IPv4/IPv6 各一条），
        // 且重复次数随主路径切到 utun 而变化。指纹必须对此稳定，
        // 否则全局模式 def1 路由生效瞬间会被误判为换网（连接→重建死循环）。
        XCTAssertEqual(physicalInterfaceFingerprint(["en0", "en0"]), "en0")
        XCTAssertEqual(
            physicalInterfaceFingerprint(["utun9", "utun9", "en0"]),
            physicalInterfaceFingerprint(["en0", "en0"]))
    }

    func test_firstObservation_doesNotTrigger() {
        var d = NetworkChangeDetector()
        XCTAssertFalse(d.observe(fingerprint: "en0"))
    }

    func test_sameNetwork_doesNotTrigger() {
        var d = NetworkChangeDetector()
        _ = d.observe(fingerprint: "en0")
        XCTAssertFalse(d.observe(fingerprint: "en0"))
        XCTAssertFalse(d.observe(fingerprint: "en0"))
    }

    func test_switchToDifferentNetwork_triggers() {
        var d = NetworkChangeDetector()
        _ = d.observe(fingerprint: "en0")
        XCTAssertTrue(d.observe(fingerprint: "en1"))
    }

    func test_emptyFingerprint_doesNotTrigger_andDoesNotMoveBaseline() {
        // WiFi → 断网 → 同一个 WiFi 回来：不应被当成换网
        var d = NetworkChangeDetector()
        _ = d.observe(fingerprint: "en0")
        XCTAssertFalse(d.observe(fingerprint: ""))      // 暂时无网
        XCTAssertFalse(d.observe(fingerprint: "en0"))   // 同网回来，不触发
    }

    func test_dropThenDifferentNetwork_triggers() {
        // WiFi-A → 断网 → WiFi-B：回来是不同网，应触发
        var d = NetworkChangeDetector()
        _ = d.observe(fingerprint: "en0")
        XCTAssertFalse(d.observe(fingerprint: ""))
        XCTAssertTrue(d.observe(fingerprint: "en1"))
    }
}
