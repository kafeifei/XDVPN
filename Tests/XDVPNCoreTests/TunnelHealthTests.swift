import XCTest
@testable import XDVPNCore

final class TunnelHealthTests: XCTestCase {

    // MARK: - 通用

    func test_notConnected_returnsNotConnected() {
        let f = TunnelFacts(declaredConnected: false, processAlive: false, mode: .full)
        XCTAssertEqual(diagnoseTunnel(f), .notConnected)
    }

    func test_processDead_anyMode() {
        for m: RunMode in [.full, .split, .proxy] {
            let f = TunnelFacts(declaredConnected: true, processAlive: false, mode: m)
            XCTAssertEqual(diagnoseTunnel(f), .processDead, "mode=\(m)")
        }
    }

    func test_withinGrace_neverJudgesBlackhole() {
        // 刚连上 5s（< grace 15s），即便信号不佳也不判黑洞，避免建链初期误杀
        let f = TunnelFacts(declaredConnected: true, processAlive: true, mode: .full,
                            secsSinceConnect: 5, graceSeconds: 15,
                            defaultRouteOnUtun: false)
        XCTAssertEqual(diagnoseTunnel(f), .healthy)
    }

    // MARK: - full 模式

    func test_full_routeEscaped_isBlackhole() {
        // def1 默认路由不再走 utun = 隧道废了
        let f = TunnelFacts(declaredConnected: true, processAlive: true, mode: .full,
                            secsSinceConnect: 60, defaultRouteOnUtun: false)
        XCTAssertEqual(diagnoseTunnel(f), .blackholeSuspect)
    }

    func test_full_routeOnUtun_andTrafficFlowing_isHealthy() {
        let f = TunnelFacts(declaredConnected: true, processAlive: true, mode: .full,
                            secsSinceConnect: 60, defaultRouteOnUtun: true,
                            inboundStalledSeconds: 0)
        XCTAssertEqual(diagnoseTunnel(f), .healthy)
    }

    func test_full_sendingButNothingComesBack_isBlackhole() {
        // 路由还在 utun，但本端在发、收方向连续停滞超阈值，且之前有过流量 → 黑洞
        let f = TunnelFacts(declaredConnected: true, processAlive: true, mode: .full,
                            secsSinceConnect: 120, defaultRouteOnUtun: true,
                            inboundStalledSeconds: 35, stallThreshold: 30,
                            hadInboundEverSinceConnect: true, outboundActive: true)
        XCTAssertEqual(diagnoseTunnel(f), .blackholeSuspect)
    }

    func test_full_idleNoTrafficEver_isHealthyNotBlackhole() {
        // 连上后用户根本没用（从没有入站流量、也没在发）→ 正常空闲，绝不能误判黑洞
        let f = TunnelFacts(declaredConnected: true, processAlive: true, mode: .full,
                            secsSinceConnect: 600, defaultRouteOnUtun: true,
                            inboundStalledSeconds: 600, stallThreshold: 30,
                            hadInboundEverSinceConnect: false, outboundActive: false)
        XCTAssertEqual(diagnoseTunnel(f), .healthy)
    }

    func test_full_stalledButNotSending_isHealthy() {
        // 收方向停滞但本端也没发包 → 只是空闲，不判黑洞
        let f = TunnelFacts(declaredConnected: true, processAlive: true, mode: .full,
                            secsSinceConnect: 120, defaultRouteOnUtun: true,
                            inboundStalledSeconds: 120, stallThreshold: 30,
                            hadInboundEverSinceConnect: true, outboundActive: false)
        XCTAssertEqual(diagnoseTunnel(f), .healthy)
    }

    // MARK: - split 模式（关键：不能用字节停滞误报，utun 长期零流量是常态）

    func test_split_byteStall_isHealthy_notBlackhole() {
        // split 下绝大多数流量不走 utun，零增长是正常的 → 进程活着就算健康
        let f = TunnelFacts(declaredConnected: true, processAlive: true, mode: .split,
                            secsSinceConnect: 600,
                            inboundStalledSeconds: 600, stallThreshold: 30,
                            hadInboundEverSinceConnect: true, outboundActive: true)
        XCTAssertEqual(diagnoseTunnel(f), .healthy)
    }

    func test_split_processDead_stillCaught() {
        let f = TunnelFacts(declaredConnected: true, processAlive: false, mode: .split)
        XCTAssertEqual(diagnoseTunnel(f), .processDead)
    }

    // MARK: - proxy 模式（靠 SOCKS5 端口可达性）

    func test_proxy_socksUnreachable_isBlackhole() {
        let f = TunnelFacts(declaredConnected: true, processAlive: true, mode: .proxy,
                            secsSinceConnect: 60, socksReachable: false)
        XCTAssertEqual(diagnoseTunnel(f), .blackholeSuspect)
    }

    func test_proxy_socksReachable_isHealthy() {
        let f = TunnelFacts(declaredConnected: true, processAlive: true, mode: .proxy,
                            secsSinceConnect: 60, socksReachable: true)
        XCTAssertEqual(diagnoseTunnel(f), .healthy)
    }
}
