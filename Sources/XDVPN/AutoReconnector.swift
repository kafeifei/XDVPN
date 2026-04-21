import Foundation
import Network

/// 非人为断开时的自动重连控制。策略：
/// - 固定 5 秒间隔，最多 5 次尝试
/// - 成功后连续 60 秒稳定 = "站稳了"，计数清零（下次再断算新一轮）
/// - 网络路径不 satisfied 时延后重连，避免空刷次数
/// - 用户主动断/连或修复成功时 cancel()
@MainActor
final class AutoReconnector {
    private weak var controller: VPNController?

    private let maxAttempts: Int = 5
    private let intervalSeconds: Int = 5
    /// 一次成功连接后，必须保持这么久"健康"才清零计数。
    /// 避免"连上 1 秒又断" 的情况每次都拿到满配重试次数。
    private let stabilityWindow: TimeInterval = 60

    private var attempt: Int = 0
    private var healthyStreakStart: Date?
    private var retryTask: Task<Void, Never>?

    /// 网络路径可用性缓存。只在 NWPathMonitor 回调里由 LifecycleWatcher 更新。
    private(set) var networkAvailable: Bool = true

    init(controller: VPNController) {
        self.controller = controller
    }

    var isRetrying: Bool { retryTask != nil }
    var currentAttempt: Int { attempt }
    var maxAttemptsConfigured: Int { maxAttempts }

    /// 心跳每次报告系统健康时叫一下。累计到 stabilityWindow 就清零计数。
    func reportHealthy() {
        let now = Date()
        if let start = healthyStreakStart {
            if now.timeIntervalSince(start) >= stabilityWindow, attempt != 0 {
                attempt = 0
            }
        } else {
            healthyStreakStart = now
        }
    }

    /// 系统状态不健康时叫 —— 清掉"连续健康"窗口起点。
    func reportUnhealthy() {
        healthyStreakStart = nil
    }

    /// 外部告知当前网络是否可达（NWPath.satisfied）。
    func setNetworkAvailable(_ available: Bool) {
        networkAvailable = available
    }

    /// 异常断开触发一次自动重连序列。若已在重连中，不重复入队。
    func scheduleReconnect(reason: String) {
        guard retryTask == nil else { return }
        healthyStreakStart = nil
        controller?.autoReconnectStarted(reason: reason)
        retryTask = Task { @MainActor [weak self] in
            await self?.runRetryLoop()
            self?.retryTask = nil
        }
    }

    /// 用户点"断开"/"连接"，或修复成功后叫。立即叫停重连流程并清零计数。
    func cancel() {
        retryTask?.cancel()
        retryTask = nil
        attempt = 0
        healthyStreakStart = nil
    }

    // MARK: - Internal loop

    private func runRetryLoop() async {
        while attempt < maxAttempts {
            attempt += 1
            guard let c = controller else { return }

            // 等网 satisfied（合盖换网时 Wi-Fi 还没连上）
            // 最多等 intervalSeconds 秒；超时也强行尝试，openconnect 会自己报错进下一轮
            var waited = 0
            while !networkAvailable, waited < intervalSeconds {
                if Task.isCancelled { return }
                c.updateReconnectCountdown(
                    attempt: attempt, maxAttempts: maxAttempts,
                    secondsLeft: intervalSeconds - waited,
                    note: "等待网络就绪…"
                )
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                waited += 1
            }

            // 倒数 5 秒显示给用户
            for remaining in stride(from: intervalSeconds, through: 1, by: -1) {
                if Task.isCancelled { return }
                c.updateReconnectCountdown(
                    attempt: attempt, maxAttempts: maxAttempts,
                    secondsLeft: remaining,
                    note: nil
                )
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if Task.isCancelled { return }

            c.updateReconnectCountdown(
                attempt: attempt, maxAttempts: maxAttempts,
                secondsLeft: 0, note: "正在重连…"
            )

            let ok = await c.attemptSilentReconnect()
            if ok {
                healthyStreakStart = Date()
                c.autoReconnectSucceeded(attempt: attempt)
                // 不立刻清零 attempt —— 由 reportHealthy 看连续 60s 后清零；
                // 如果马上又掉，算在同一轮里（避免"连 1 秒断 1 秒"无限白嫖 5 次）
                return
            }
            if Task.isCancelled { return }
            // 失败就进下一轮（attempt 已 +1）
        }
        // 所有次数用完
        controller?.autoReconnectGaveUp()
        // 不在这里清零 attempt —— 让 UI 能显示 "5/5 失败"；用户下次手动连接时会清
    }
}
