import Foundation

public enum DomainRuleConfigError: Error, Equatable, LocalizedError, Sendable {
    case invalidSuffix(line: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidSuffix(let line):
            return "Invalid domain suffix at line \(line)"
        }
    }
}

/// Shared domain-suffix normalization for the app and the privileged DNS proxy.
public enum DomainRules {
    public static func parseSuffixList(_ raw: String) -> [String] {
        normalizedSuffixes(
            raw.components(separatedBy: CharacterSet(charactersIn: ",\n")),
            rejectInvalid: false
        ).suffixes
    }

    /// Parses the root helper's line-oriented config and rejects the entire file
    /// when any active line is invalid.
    public static func parseValidatedConfig(_ raw: String) throws -> [String] {
        let result = normalizedSuffixes(
            raw.components(separatedBy: .newlines),
            rejectInvalid: true
        )
        if let line = result.invalidLine {
            throw DomainRuleConfigError.invalidSuffix(line: line)
        }
        return result.suffixes
    }

    public static func isValidDomainSuffix(_ suffix: String) -> Bool {
        guard !suffix.isEmpty, suffix.utf8.count <= 253 else { return false }
        let labels = suffix.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63
                && label.allSatisfy {
                    $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")
                }
                && !label.hasPrefix("-") && !label.hasSuffix("-")
        }
    }

    private static func normalizedSuffixes(
        _ lines: [String],
        rejectInvalid: Bool
    ) -> (suffixes: [String], invalidLine: Int?) {
        var suffixes: [String] = []
        var seen = Set<String>()
        for (index, rawLine) in lines.enumerated() {
            var suffix = rawLine.trimmingCharacters(in: .whitespaces).lowercased()
            if suffix.isEmpty || suffix.hasPrefix("#") { continue }
            if suffix.hasPrefix("*.") { suffix.removeFirst(2) }
            guard isValidDomainSuffix(suffix) else {
                if rejectInvalid { return ([], index + 1) }
                continue
            }
            if seen.insert(suffix).inserted { suffixes.append(suffix) }
        }
        return (suffixes, nil)
    }
}
