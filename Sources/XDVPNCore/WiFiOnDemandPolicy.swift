import Foundation

public enum WiFiOnDemandAction: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case connectVPN
    case disconnectVPN

    public var id: String { rawValue }
}

public struct WiFiOnDemandRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var ssid: String
    public var action: WiFiOnDemandAction

    public init(id: UUID = UUID(), ssid: String, action: WiFiOnDemandAction) {
        self.id = id
        self.ssid = Self.normalizedSSID(ssid)
        self.action = action
    }

    public static func normalizedSSID(_ ssid: String) -> String {
        ssid.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum WiFiOnDemandDecision: Equatable, Sendable {
    case noMatch
    case connect
    case disconnect
}

public struct WiFiOnDemandPolicy: Equatable, Sendable {
    public var isEnabled: Bool
    public var rules: [WiFiOnDemandRule]

    public init(isEnabled: Bool, rules: [WiFiOnDemandRule]) {
        self.isEnabled = isEnabled
        self.rules = rules
    }

    public func decision(for ssid: String?) -> WiFiOnDemandDecision {
        guard isEnabled,
              let ssid,
              !WiFiOnDemandRule.normalizedSSID(ssid).isEmpty else {
            return .noMatch
        }

        let normalized = WiFiOnDemandRule.normalizedSSID(ssid)
        guard let rule = rules.first(where: { $0.ssid == normalized }) else {
            return .noMatch
        }

        switch rule.action {
        case .connectVPN:
            return .connect
        case .disconnectVPN:
            return .disconnect
        }
    }

    public static func replacingOrAppending(
        _ rules: [WiFiOnDemandRule],
        ssid: String,
        action: WiFiOnDemandAction
    ) -> [WiFiOnDemandRule] {
        let normalized = WiFiOnDemandRule.normalizedSSID(ssid)
        guard !normalized.isEmpty else { return rules }

        var updated = rules
        if let idx = updated.firstIndex(where: { $0.ssid == normalized }) {
            updated[idx].action = action
        } else {
            updated.append(WiFiOnDemandRule(ssid: normalized, action: action))
        }
        return updated
    }
}
