import Foundation

public struct RouteScriptSession: Equatable, Sendable {
    public var tunnelInterface: String
    public var vpnGateway: String?
    public var routes: [String]
    public var dnsProxyActive: Bool

    public init(
        tunnelInterface: String,
        vpnGateway: String?,
        routes: [String],
        dnsProxyActive: Bool
    ) {
        self.tunnelInterface = tunnelInterface
        self.vpnGateway = vpnGateway
        self.routes = routes
        self.dnsProxyActive = dnsProxyActive
    }

    public static func parse(_ content: String) -> RouteScriptSession? {
        var tunnelInterface: String?
        var vpnGateway: String?
        var routes: [String] = []
        var dnsProxyActive = false

        for line in content.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let key = String(parts[0])
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            switch key {
            case "TUNDEV":
                tunnelInterface = value
            case "VPNGATEWAY":
                vpnGateway = value
            case "ROUTE_NET":
                routes.append(value)
            case "DNS_PROXY_PID":
                dnsProxyActive = true
            default:
                break
            }
        }

        guard let tunnelInterface else { return nil }
        return RouteScriptSession(
            tunnelInterface: tunnelInterface,
            vpnGateway: vpnGateway,
            routes: routes,
            dnsProxyActive: dnsProxyActive
        )
    }
}
