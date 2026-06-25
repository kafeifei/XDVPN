import XCTest
@testable import XDVPNCore

final class LogRedactionTests: XCTestCase {

    func test_containsPassword_isReplaced() {
        let line = "connecting with password hunter2 to server"
        XCTAssertEqual(
            redactSecrets(line, secrets: ["hunter2"]),
            "connecting with password *** to server")
    }

    func test_emptySecretList_returnsUnchanged() {
        let line = "nothing secret here"
        XCTAssertEqual(redactSecrets(line, secrets: []), line)
    }

    func test_passwordAppearsMultipleTimes_allReplaced() {
        let line = "pw=s3cret retry pw=s3cret again s3cret"
        XCTAssertEqual(
            redactSecrets(line, secrets: ["s3cret"]),
            "pw=*** retry pw=*** again ***")
    }

    func test_emptyStringSecret_doesNotAffectLine() {
        // 空串 secret 必须被忽略，绝不能把每个字符间隙都替换成 ***
        let line = "abc"
        XCTAssertEqual(redactSecrets(line, secrets: [""]), "abc")
    }

    func test_emptyStringSecret_mixedWithRealSecret() {
        // 空串被忽略，真实 secret 仍被替换
        let line = "token=abcdef end"
        XCTAssertEqual(
            redactSecrets(line, secrets: ["", "abcdef"]),
            "token=*** end")
    }

    func test_overlappingSecrets_longerReplacedFirst() {
        // 按长度降序替换，避免短 secret 是长 secret 子串时把长的拆碎
        // "pass" 是 "password123" 的子串；先替换长的，"password123" 整体变 ***
        let line = "my password123 value"
        XCTAssertEqual(
            redactSecrets(line, secrets: ["pass", "password123"]),
            "my *** value")
    }

    func test_secretNotPresent_unchanged() {
        let line = "harmless log line"
        XCTAssertEqual(redactSecrets(line, secrets: ["nothere"]), line)
    }
}
