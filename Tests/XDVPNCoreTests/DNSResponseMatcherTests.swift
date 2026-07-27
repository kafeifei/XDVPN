import XCTest
@testable import XDVPNCore

final class DNSResponseMatcherTests: XCTestCase {
    func test_matchesEchoedQuestionCaseInsensitively() {
        let query = packet(id: 0x1234, name: "Example.COM", response: false)
        let response = packet(id: 0x1234, name: "example.com", response: true)
        XCTAssertTrue(DNSResponseMatcher.matches(query: query, response: response))
    }

    func test_rejectsWrongIDQuestionOrPacketDirection() {
        let query = packet(id: 0x1234, name: "example.com", response: false)
        XCTAssertFalse(DNSResponseMatcher.matches(
            query: query,
            response: packet(id: 0x5678, name: "example.com", response: true)
        ))
        XCTAssertFalse(DNSResponseMatcher.matches(
            query: query,
            response: packet(id: 0x1234, name: "other.com", response: true)
        ))
        XCTAssertFalse(DNSResponseMatcher.matches(
            query: query,
            response: packet(id: 0x1234, name: "example.com", response: false)
        ))
    }

    func test_rejectsMalformedCompressedQuestion() {
        let query = packet(id: 1, name: "example.com", response: false)
        var response = packet(id: 1, name: "example.com", response: true)
        response.replaceSubrange(12..<25, with: [0xC0, 0x0C])
        XCTAssertFalse(DNSResponseMatcher.matches(query: query, response: response))
    }

    private func packet(id: UInt16, name: String, response: Bool) -> [UInt8] {
        var bytes: [UInt8] = [
            UInt8(id >> 8), UInt8(id & 0xFF), response ? 0x81 : 0x01, 0x00,
            0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        for label in name.split(separator: ".") {
            bytes.append(UInt8(label.utf8.count))
            bytes.append(contentsOf: label.utf8)
        }
        bytes.append(contentsOf: [0x00, 0x00, 0x01, 0x00, 0x01])
        return bytes
    }
}
