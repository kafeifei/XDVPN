import AppKit
import Foundation
import SwiftUI

/// 状态点颜色（UI 小圆点用）。
enum StatusDot { case green, yellow, red, gray }

/// 用户意图：与系统实际状态解耦，让"我声称连着，但系统其实断了" 成为可观察信号。
enum UserIntent { case connect, disconnect }

/// 应用的总控。拥有 1 Hz 心跳、LifecycleWatcher、AutoReconnector。
/// 所有系统真实状态 → 走 HealthChecker 诊断 → 由此处决策。
@MainActor
final class VPNController: ObservableObject {
    // MARK: - 表单（持久化字段）
    @Published var protocolName: String = "anyconnect"
    @Published var server: String = ""
    @Published var user: String = ""
    @Published var password: String = ""
    @Published var rememberPassword: Bool = true

    // MARK: - UI 状态
    /// 用户意图。被 connect / disconnect 改变，不被 sleep / 崩溃改变。
    @Published private(set) var intent: UserIntent = .disconnect
    /// 系统此刻是否实际连着（心跳判定）。驱动菜单栏图标色彩。
    @Published private(set) var isConnected: Bool = false
    /// 有同步阻塞操作进行中（正在连/断/修复）。按钮禁用期。
    @Published private(set) var isBusy: Bool = false
    /// 单行状态文案。含倒数、重连次数等动态信息。
    @Published private(set) var statusText: String = "未连接"
    /// 单行状态点颜色。
    @Published private(set) var statusColor: StatusDot = .gray
    /// 自动重连进行中时 > 0，否则 0。驱动 UI 的"x/y 倒数 z 秒"显示。
    @Published private(set) var retryAttempt: Int = 0
    @Published private(set) var retryMax: Int = 0
    @Published private(set) var retrySeconds: Int = 0
    /// 心跳发现残留路由 / 自动重连放弃时置 true，UI 显示"修复路由"按钮。
    @Published private(set) var needsRepair: Bool = false
    /// 免密 sudo 是否已配置。决定是否显示"一键配置"行。
    @Published private(set) var sudoConfigured: Bool = SudoersInstaller.isInstalled

    // MARK: - 子系统
    private var heartbeat: Timer?
    private var lifecycle: LifecycleWatcher?
    private lazy var reconnector: AutoReconnector = .init(controller: self)
    /// 锁定状态文案到某时刻（用于显示错误 —— 防止下一次心跳立刻覆盖）
    private var statusLockedUntil: Date?

    init() {
        loadPrefs()
        lifecycle = LifecycleWatcher(controller: self)
        // 冷启动推断意图：若有活 openconnect → 当作用户仍想连着（继承上次的会话）
        if OpenConnectRunner.isRunning { intent = .connect }
        performHealthTick()
        startHeartbeat()
    }

    deinit {
        heartbeat?.invalidate()
    }

    // MARK: - Prefs / Keychain

    private var keychainAccount: String { "\(user)@\(server)" }

    func savePrefs() {
        let d = UserDefaults.standard
        d.set(protocolName, forKey: "xdvpn.protocol")
        d.set(server, forKey: "xdvpn.server")
        d.set(user, forKey: "xdvpn.user")
        d.set(rememberPassword, forKey: "xdvpn.remember")
    }

    private func loadPrefs() {
        let d = UserDefaults.standard
        protocolName = d.string(forKey: "xdvpn.protocol") ?? "anyconnect"
        server = d.string(forKey: "xdvpn.server") ?? ""
        user = d.string(forKey: "xdvpn.user") ?? ""
        rememberPassword = d.object(forKey: "xdvpn.remember") as? Bool ?? true
        if rememberPassword, !user.isEmpty, !server.isEmpty {
            password = KeychainStore.load(account: keychainAccount) ?? ""
        }
    }

    var canConnect: Bool {
        !server.isEmpty && !user.isEmpty && !password.isEmpty
            && !isBusy && !isConnected && sudoConfigured
    }

    // MARK: - 用户动作

    func connect() {
        guard canConnect else { return }
        intent = .connect
        reconnector.cancel()
        needsRepair = false
        isBusy = true
        setStatus("正在连接…", .yellow)

        let p = protocolName, s = server, u = user, pw = password
        let remember = rememberPassword
        let account = keychainAccount
        Task.detached { [weak self] in
            do {
                try await BiometricGate.ensure()
                try OpenConnectRunner.connect(
                    protocolName: p, server: s, user: u, password: pw
                )
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if remember {
                        KeychainStore.save(password: pw, account: account)
                    } else {
                        KeychainStore.delete(account: account)
                    }
                    self.savePrefs()
                    BiometricGate.markActivity()
                    self.isBusy = false
                    self.performHealthTick()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isBusy = false
                    if case VPNError.sudoNotConfigured = error {
                        self.sudoConfigured = false
                    }
                    self.intent = .disconnect
                    self.setStatus(error.localizedDescription, .red, lockFor: 15)
                }
            }
        }
    }

    func disconnect() {
        intent = .disconnect
        reconnector.cancel()
        disconnectInternal(reason: "正在断开…（等路由回收）")
    }

    /// 合盖/睡眠前的"立即断开、同步等待"。willSleep 给 ~20 s 时间，够用。
    /// 断不干净就直接 repair 兜底，宁可多做，不留残局。
    ///
    /// **不改 intent**：睡眠是系统动作，不是用户主动断开。保持 intent=.connect 让
    /// 唤醒后的心跳触发自动重连；若睡前本来就是 .disconnect 也不破坏。
    func disconnectForSleep() {
        reconnector.cancel()
        isBusy = true
        setStatus("睡眠前清理连接…", .yellow)
        do {
            try OpenConnectRunner.disconnect()
        } catch {
            try? OpenConnectRunner.repair()
        }
        isBusy = false
        performHealthTick()
    }

    private func disconnectInternal(reason: String) {
        isBusy = true
        setStatus(reason, .yellow)
        Task.detached { [weak self] in
            let errMsg: String? = {
                do {
                    try OpenConnectRunner.disconnect()
                    return nil
                } catch let e as VPNError {
                    if case .disconnectStuck = e {
                        // 卡住了 —— 自动走 repair 兜底，吞掉 stuck 错误
                        try? OpenConnectRunner.repair()
                        return nil
                    }
                    return e.localizedDescription
                } catch {
                    return error.localizedDescription
                }
            }()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isBusy = false
                if let errMsg { self.setStatus(errMsg, .red, lockFor: 10) }
                self.performHealthTick()
            }
        }
    }

    /// 用户手动点"修复路由"（心跳诊断为 ghostRoute 或自动重连放弃时 UI 会给按钮）
    func repairRoutes() {
        isBusy = true
        setStatus("正在修复路由…", .yellow)
        Task.detached { [weak self] in
            let errMsg: String? = {
                do { try OpenConnectRunner.repair(); return nil }
                catch { return error.localizedDescription }
            }()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isBusy = false
                if let errMsg {
                    self.setStatus("修复失败：\(errMsg)", .red, lockFor: 20)
                } else {
                    self.needsRepair = false
                    self.intent = .disconnect
                    self.reconnector.cancel()
                    self.setStatus("已修复", .gray, lockFor: 3)
                    self.performHealthTick()
                }
            }
        }
    }

    // MARK: - Sudoers 配置入口

    func installSudoers() {
        isBusy = true
        Task.detached { [weak self] in
            let errMsg: String? = {
                do { try SudoersInstaller.install(); return nil }
                catch { return error.localizedDescription }
            }()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isBusy = false
                self.sudoConfigured = SudoersInstaller.isInstalled
                if let errMsg { self.setStatus(errMsg, .red, lockFor: 15) }
            }
        }
    }

    func uninstallSudoers() {
        isBusy = true
        Task.detached { [weak self] in
            try? SudoersInstaller.uninstall()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isBusy = false
                self.sudoConfigured = SudoersInstaller.isInstalled
            }
        }
    }

    // MARK: - 状态文案锁定

    private func setStatus(_ text: String, _ color: StatusDot, lockFor: TimeInterval = 0) {
        statusText = text
        statusColor = color
        statusLockedUntil = lockFor > 0 ? Date().addingTimeInterval(lockFor) : nil
    }

    private var canUpdateStatus: Bool {
        if let u = statusLockedUntil {
            if Date() < u { return false }
            statusLockedUntil = nil
        }
        return true
    }

    // MARK: - 1Hz 心跳

    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performHealthTick()
            }
        }
    }

    /// 取一次系统快照、诊断、推动状态。任何场景下每秒执行。
    func performHealthTick() {
        let sample = HealthChecker.sample()
        let verdict = HealthChecker.diagnose(
            declaredConnected: intent == .connect,
            state: sample
        )
        // 每次都更新 isConnected：驱动菜单栏图标色彩
        let healthy = (verdict == .healthyConnected)
        if self.isConnected != healthy { self.isConnected = healthy }

        // 关键动作期间不干预（避免"正在断开"被 ghostRoute 打岔、"正在连接"被 openconnectDied 打岔）
        if isBusy { return }

        switch verdict {
        case .healthyConnected:
            needsRepair = false
            reconnector.reportHealthy()
            if !reconnector.isRetrying, canUpdateStatus {
                setStatus("已连接", .green)
            }

        case .healthyDisconnected:
            needsRepair = false
            reconnector.reportHealthy()
            if !reconnector.isRetrying, canUpdateStatus {
                setStatus("未连接", .gray)
            }

        case .openconnectDied:
            reconnector.reportUnhealthy()
            if intent == .connect, !reconnector.isRetrying {
                reconnector.scheduleReconnect(reason: "连接已丢失")
            } else if canUpdateStatus, !reconnector.isRetrying {
                setStatus("未连接", .gray)
            }

        case .routeEscaped:
            reconnector.reportUnhealthy()
            if intent == .connect, !reconnector.isRetrying {
                // 让 openconnect 先收尾，下一 tick 会变成 openconnectDied 触发 AR
                disconnectInternal(reason: "网络切换，清理旧连接…")
            }

        case .ghostRoute:
            needsRepair = true
            if !reconnector.isRetrying, canUpdateStatus {
                setStatus("检测到残留路由，请点修复", .red)
            }

        case .networkDown:
            if !reconnector.isRetrying, canUpdateStatus {
                setStatus("等待网络恢复…", .gray)
            }
        }
    }

    // MARK: - LifecycleWatcher 回调

    func refreshAfterWake() {
        // 唤醒后 1.5 s 再判：等 Wi-Fi 重新握上、DHCP 完成，免得误报 networkDown
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.performHealthTick()
        }
    }

    func networkChangedWhileConnected() {
        guard intent == .connect, !isBusy else { return }
        // 物理接口集合变化 = 合盖换网 / 插拔网线 —— 旧 openconnect 基本废了，清空重建
        disconnectInternal(reason: "网络已切换，重建连接…")
    }

    func networkReachabilityChanged(_ reachable: Bool) {
        reconnector.setNetworkAvailable(reachable)
    }

    // MARK: - AutoReconnector 回调

    func autoReconnectStarted(reason: String) {
        retryAttempt = 0
        retryMax = reconnector.maxAttemptsConfigured
        retrySeconds = 0
        setStatus("\(reason)，准备自动重连", .yellow)
    }

    func updateReconnectCountdown(
        attempt: Int, maxAttempts: Int, secondsLeft: Int, note: String?
    ) {
        retryAttempt = attempt
        retryMax = maxAttempts
        retrySeconds = secondsLeft
        let base: String
        if let note, !note.isEmpty {
            base = "\(note)（\(attempt)/\(maxAttempts)）"
        } else if secondsLeft > 0 {
            base = "自动重连 \(attempt)/\(maxAttempts)：\(secondsLeft) 秒后重试"
        } else {
            base = "正在重连…（\(attempt)/\(maxAttempts)）"
        }
        setStatus(base, .yellow)
    }

    func autoReconnectSucceeded(attempt: Int) {
        retryAttempt = 0
        retryMax = 0
        retrySeconds = 0
        needsRepair = false
        BiometricGate.markActivity()
        setStatus(attempt > 0 ? "已连接（第 \(attempt) 次重连成功）" : "已连接", .green)
    }

    func autoReconnectGaveUp() {
        let m = reconnector.maxAttemptsConfigured
        retrySeconds = 0
        needsRepair = true
        setStatus("自动重连失败 \(m)/\(m)，请修复或重连", .red, lockFor: 30)
    }

    /// AR 调：用保存的凭据无弹窗重连。不走 BiometricGate（用户此刻不在眼前）。
    /// 先跑一次 repair 清残局，再连；成功与否返回给 AR。
    func attemptSilentReconnect() async -> Bool {
        guard !password.isEmpty, !server.isEmpty, !user.isEmpty else { return false }
        let p = protocolName, s = server, u = user, pw = password

        // 清残局（死 openconnect、utun 默认路由、vpnc-script 孤儿状态）
        try? await Task.detached { try OpenConnectRunner.repair() }.value

        do {
            try await Task.detached {
                try OpenConnectRunner.connect(
                    protocolName: p, server: s, user: u, password: pw
                )
            }.value
            return true
        } catch {
            return false
        }
    }
}
