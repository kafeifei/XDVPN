import XCTest
@testable import XDVPNCore

final class ReconnectPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    // MARK: - bug②/③：硬失败必须沿退避链推进，而不是只试 1 次

    func test_hardFailure_advancesThroughFullBackoffThenGivesUp() {
        var p = ReconnectPolicy(maxAttempts: 5, delays: [1, 2, 4, 8, 16])

        // 首次掉线
        XCTAssertEqual(p.onTunnelLost(now: at(0)), .scheduleReconnect(delay: 1, attempt: 1))
        // 之后每次重连 connect 抛错 → 必须推进到下一档，而不是停在第 1 次
        XCTAssertEqual(p.onReconnectAttemptFailed(now: at(1)), .scheduleReconnect(delay: 2, attempt: 2))
        XCTAssertEqual(p.onReconnectAttemptFailed(now: at(3)), .scheduleReconnect(delay: 4, attempt: 3))
        XCTAssertEqual(p.onReconnectAttemptFailed(now: at(7)), .scheduleReconnect(delay: 8, attempt: 4))
        XCTAssertEqual(p.onReconnectAttemptFailed(now: at(15)), .scheduleReconnect(delay: 16, attempt: 5))
        // 第 6 次 → 超过上限 → 放弃，并把计数清零（下一轮重新算）
        XCTAssertEqual(p.onReconnectAttemptFailed(now: at(31)), .giveUp)
        XCTAssertEqual(p.attempt, 0)
    }

    // MARK: - bug①：连上瞬间不清零；只有稳定存活满 stabilityWindow 才清零

    func test_connectSucceeded_doesNotResetAttempt() {
        var p = ReconnectPolicy(maxAttempts: 5, stabilityWindow: 60)
        _ = p.onTunnelLost(now: at(0))            // attempt = 1
        _ = p.onReconnectAttemptFailed(now: at(1)) // attempt = 2
        p.onConnectSucceeded(now: at(2))          // 建链成功
        // 关键：建链成功不得把 attempt 清零（否则抖动无限重连）
        XCTAssertEqual(p.attempt, 2)
    }

    func test_attemptResetsOnlyAfterStableSurvival() {
        var p = ReconnectPolicy(maxAttempts: 5, stabilityWindow: 60)
        _ = p.onTunnelLost(now: at(0))   // attempt = 1
        p.onConnectSucceeded(now: at(10))
        // 还没满 60s：心跳健康但不清零
        p.onHealthyTick(now: at(40))     // 存活 30s
        XCTAssertEqual(p.attempt, 1)
        // 满 60s 连续健康 → 认定站稳，清零
        p.onHealthyTick(now: at(70))     // 存活 60s
        XCTAssertEqual(p.attempt, 0)
    }

    // MARK: - 抖动：连上又秒断，计数必须持续累加最终放弃，绝不无限重连

    func test_flapping_keepsAdvancing_doesNotResetForever() {
        var p = ReconnectPolicy(maxAttempts: 5, stabilityWindow: 60)
        var t: TimeInterval = 0
        for expectedAttempt in 1...5 {
            let cmd = p.onTunnelLost(now: at(t))
            XCTAssertEqual(cmd, .scheduleReconnect(delay: p.delays[min(expectedAttempt - 1, p.delays.count - 1)],
                                                   attempt: expectedAttempt))
            // 模拟「连上 3 秒又断」：成功后没到 60s 就丢
            t += 1
            p.onConnectSucceeded(now: at(t))
            t += 3
        }
        // 第 6 次掉线 → 放弃（说明上限真的生效，不是无限重连）
        XCTAssertEqual(p.onTunnelLost(now: at(t)), .giveUp)
    }

    // MARK: - 健康中断：不连续的健康不算稳定，不得清零

    func test_unhealthyTickBreaksStreak() {
        var p = ReconnectPolicy(maxAttempts: 5, stabilityWindow: 60)
        _ = p.onTunnelLost(now: at(0))   // attempt = 1
        p.onConnectSucceeded(now: at(0))
        p.onHealthyTick(now: at(30))     // 存活 30s
        p.onUnhealthyTick()              // 黑洞/异常打断
        p.onHealthyTick(now: at(50))     // 重新开始计 streak（从 50s 算）
        p.onHealthyTick(now: at(80))     // 距重新开始才 30s，不到 60s
        XCTAssertEqual(p.attempt, 1)     // 不得清零
        p.onHealthyTick(now: at(115))    // 距 50s 已 65s
        XCTAssertEqual(p.attempt, 0)
    }

    // MARK: - 用户主动操作 → 整体清零

    func test_reset_clearsCounterAndStreak() {
        var p = ReconnectPolicy(maxAttempts: 5)
        _ = p.onTunnelLost(now: at(0))
        _ = p.onReconnectAttemptFailed(now: at(1))
        XCTAssertEqual(p.attempt, 2)
        p.reset()
        XCTAssertEqual(p.attempt, 0)
        XCTAssertNil(p.healthyStreakStart)
        // 清零后下一次掉线又从第 1 次开始
        XCTAssertEqual(p.onTunnelLost(now: at(5)), .scheduleReconnect(delay: 1, attempt: 1))
    }

    // MARK: - 退避档位用尽后保持最后一档（防越界）

    func test_delaysClampAtLastStep() {
        var p = ReconnectPolicy(maxAttempts: 8, delays: [1, 2, 4])
        XCTAssertEqual(p.onTunnelLost(now: at(0)), .scheduleReconnect(delay: 1, attempt: 1))
        XCTAssertEqual(p.onReconnectAttemptFailed(now: at(1)), .scheduleReconnect(delay: 2, attempt: 2))
        XCTAssertEqual(p.onReconnectAttemptFailed(now: at(2)), .scheduleReconnect(delay: 4, attempt: 3))
        // 第 4、5… 次都用最后一档 4s
        XCTAssertEqual(p.onReconnectAttemptFailed(now: at(3)), .scheduleReconnect(delay: 4, attempt: 4))
        XCTAssertEqual(p.onReconnectAttemptFailed(now: at(4)), .scheduleReconnect(delay: 4, attempt: 5))
    }
}
