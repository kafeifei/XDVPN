import XCTest
@testable import XDVPNCore

final class DomainRulesTests: XCTestCase {
    func test_parseSuffixList_normalizesFiltersAndDeduplicates() {
        XCTAssertEqual(
            DomainRules.parseSuffixList(
                "*.Example.COM, b.com\n# comment\n-bad.com\nexample.com"
            ),
            ["example.com", "b.com"]
        )
    }

    func test_domainLengthBoundaries() {
        XCTAssertTrue(DomainRules.isValidDomainSuffix(
            String(repeating: "a", count: 63) + ".com"
        ))
        XCTAssertFalse(DomainRules.isValidDomainSuffix(
            String(repeating: "a", count: 64) + ".com"
        ))
        XCTAssertFalse(DomainRules.isValidDomainSuffix(
            [String](repeating: String(repeating: "a", count: 63), count: 4)
                .joined(separator: ".")
        ))
    }

    func test_parseValidatedConfig_rejectsWholeFileAtInvalidLine() {
        XCTAssertThrowsError(
            try DomainRules.parseValidatedConfig("example.com\n../../tmp/owned\nsafe.com")
        ) { error in
            XCTAssertEqual(error as? DomainRuleConfigError, .invalidSuffix(line: 2))
        }
    }

    func test_parseValidatedConfig_acceptsCommentsAndNormalizesWildcards() throws {
        XCTAssertEqual(
            try DomainRules.parseValidatedConfig("# comment\n*.Example.com\nexample.com\n"),
            ["example.com"]
        )
    }
}
