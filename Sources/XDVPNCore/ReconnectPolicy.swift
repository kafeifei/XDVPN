import Foundation

/// 自动重连的纯决策状态机（无副作用、无 AppKit、可单测）。
///
/// 它只拥有「重试计数 + 退避节奏 + 何时清零 / 何时放弃」这一份逻辑，
/// 修正历史上散落在 VPNController 里的三个 bug：
///   ① 连上瞬间立即清零计数 → 抖动场景无限重连。改为「稳定存活 stabilityWindow 秒才清零」。
///   ② 硬失败后不再推进退避 → 只试 1 次就放弃。改为失败也推进退避直到 maxAttempts。
///   ③ （网络就绪门控由调用方据 schedule 命令实现，本类只负责计数与延迟。）
///
/// 调用方契约：拿到 `.scheduleReconnect(delay:attempt:)` 后，等 delay 秒 + 网络就绪，
/// 再发起一次静默重连；该次 connect 失败就调 `onReconnectAttemptFailed` 拿下一条命令。
public enum ReconnectCommand: Equatable, Sendable {
    /// 等 delay 秒后发起第 attempt 次重连。
    case scheduleReconnect(delay: TimeInterval, attempt: Int)
    /// 已达上限，放弃自动重连。
    case giveUp
}

public struct ReconnectPolicy: Sendable {
    public let maxAttempts: Int
    public let stabilityWindow: TimeInterval
    public let delays: [TimeInterval]

    public private(set) var attempt: Int = 0
    public private(set) var healthyStreakStart: Date? = nil

    public init(
        maxAttempts: Int = 5,
        stabilityWindow: TimeInterval = 60,
        delays: [TimeInterval] = [1, 2, 4, 8, 16]
    ) {
        self.maxAttempts = maxAttempts
        self.stabilityWindow = stabilityWindow
        self.delays = delays
    }

    /// 检测到非用户意图的掉线 → 开启/推进一轮退避。
    public mutating func onTunnelLost(now: Date) -> ReconnectCommand { advance() }

    /// 一次自动重连的 connect 失败 → 沿退避链推进（修 bug②，不再单次放弃）。
    public mutating func onReconnectAttemptFailed(now: Date) -> ReconnectCommand { advance() }

    /// 隧道刚（重）建好。**不**清零计数（修 bug①），只开始记「稳定存活」起点。
    public mutating func onConnectSucceeded(now: Date) {
        healthyStreakStart = now
    }

    /// 连接健康的周期心跳。仅当连续健康满 stabilityWindow 才认定站稳、清零计数。
    public mutating func onHealthyTick(now: Date) {
        guard let start = healthyStreakStart else {
            healthyStreakStart = now
            return
        }
        if now.timeIntervalSince(start) >= stabilityWindow {
            attempt = 0
        }
    }

    /// 健康中断（黑洞/异常）→ 打断稳定计时，下次健康从头算。
    public mutating func onUnhealthyTick() {
        healthyStreakStart = nil
    }

    /// 用户主动连/断 → 整体清零。
    public mutating func reset() {
        attempt = 0
        healthyStreakStart = nil
    }

    private mutating func advance() -> ReconnectCommand {
        attempt += 1
        healthyStreakStart = nil
        if attempt > maxAttempts {
            attempt = 0
            return .giveUp
        }
        let idx = min(attempt - 1, delays.count - 1)
        return .scheduleReconnect(delay: delays[idx], attempt: attempt)
    }
}
