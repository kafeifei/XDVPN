import XCTest
@testable import XDVPNCore

final class RouteScriptSessionTests: XCTestCase {
    func test_parsesRouteScriptSession() {
        let content = """
        # xdvpn session 2026-07-05T04:33:28Z
        TUNDEV=utun11
        VPNGATEWAY=198.18.0.130
        ROUTE_HOST=198.18.0.130
        ROUTE_NET=10.0.0.0/8
        ROUTE_NET=172.16.0.0/12
        DNS_PROXY_PID=12345
        """

        XCTAssertEqual(
            RouteScriptSession.parse(content),
            RouteScriptSession(
                tunnelInterface: "utun11",
                vpnGateway: "198.18.0.130",
                routes: ["10.0.0.0/8", "172.16.0.0/12"],
                dnsProxyActive: true
            )
        )
    }

    func test_requiresTunnelInterfaceBeforeApplyingSnapshot() {
        let content = """
        # xdvpn session is being rewritten
        VPNGATEWAY=198.18.0.130
        ROUTE_NET=10.0.0.0/8
        """

        XCTAssertNil(RouteScriptSession.parse(content))
    }

    func test_trimsValuesAndIgnoresEmptyValues() {
        let content = """
        TUNDEV= utun9
        VPNGATEWAY=
        ROUTE_NET= 10.0.0.0/8
        """

        XCTAssertEqual(
            RouteScriptSession.parse(content),
            RouteScriptSession(
                tunnelInterface: "utun9",
                vpnGateway: nil,
                routes: ["10.0.0.0/8"],
                dnsProxyActive: false
            )
        )
    }
}
