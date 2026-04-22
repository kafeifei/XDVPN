import AppKit
import Foundation
import SwiftUI

/// 总控。v0.3 相比 v0.2 大幅瘦身：
/// - 删掉 HealthChecker（1Hz 轮询路由表的复杂逻辑不再需要 —— def1 路由天然可恢复）
/// - 删掉 LifecycleWatcher（sleep 处理直接塞 init，没必要单起一个 class）
/// - 删掉 AutoReconnector（自动重连是独立 feature，v0.3 先不做；用户手动重连也是 2 秒的事）
/// - 删掉 needsRepair / intent / StatusDot / statusLockedUntil 等过度设计
///
/// 现在就是一个普通的 ObservableObject：
/// - init 时跑一次 cleanup（self-heal）
/// - connect 前再跑一次 cleanup（确保干净起点）
/// - 2s Timer 轮询 pid，发现异常死亡 → 自动 cleanup
/// - willSleep → 同步 cleanup
@MainActor
final class VPNController: ObservableObject {
    // MARK: - 表单

    @Published var protocolName: String = "anyconnect"
    @Published var server: String = ""
    @Published var user: String = ""
    @Published var password: String = ""
    @Published var rememberPassword: Bool = true

    // MARK: - 状态

    @Published private(set) var isConnected: Bool = false
    @Published private(set) var isBusy: Bool = false
    @Published private(set) var statusText: String = "未连接"
    @Published private(set) var sudoConfigured: Bool = SudoersInstaller.isInstalled

    // MARK: - 私有

    private var pollTimer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    /// 睡前是否连着 → 醒来自动重连
    private var shouldReconnectAfterWake = false

    init() {
        loadPrefs()
        // Self-heal：启动时先清上次的残余（幂等，没残余就秒过）
        // 只有 sudoers 已配的情况下才跑 —— 首次启动时 cleanup helper 还不存在
        if sudoConfigured {
            runCleanupDetached(reason: "启动清理上次残余")
        }
        startPolling()
        registerSleepHook()
    }

    deinit {
        pollTimer?.invalidate()
        let nc = NSWorkspace.shared.notificationCenter
        if let obs = sleepObserver { nc.removeObserver(obs) }
        if let obs = wakeObserver { nc.removeObserver(obs) }
    }

    // MARK: - Preferences / Keychain

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
        sudoConfigured && !server.isEmpty && !user.isEmpty && !password.isEmpty
            && !isBusy && !isConnected
    }

    // MARK: - 用户动作

    func connect() {
        guard canConnect else { return }
        isBusy = true
        statusText = "正在连接…"

        let p = protocolName, s = server, u = user, pw = password
        let remember = rememberPassword
        let account = keychainAccount

        Task.detached { [weak self] in
            // 先 cleanup 确保干净起点（即使启动时跑过，用户可能在期间手动 kill 过什么）
            try? OpenConnectRunner.cleanup()

            // 连接
            let result: Result<Void, Error>
            do {
                try await BiometricGate.ensure()
                try OpenConnectRunner.connect(
                    protocolName: p, server: s, user: u, password: pw
                )
                result = .success(())
            } catch {
                result = .failure(error)
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isBusy = false
                switch result {
                case .success:
                    if remember {
                        KeychainStore.save(password: pw, account: account)
                    } else {
                        KeychainStore.delete(account: account)
                    }
                    self.savePrefs()
                    BiometricGate.markActivity()
                    self.isConnected = true
                    self.statusText = "已连接"
                case .failure(let err):
                    if case VPNError.sudoNotConfigured = err {
                        self.sudoConfigured = false
                    }
                    self.isConnected = false
                    self.statusText = err.localizedDescription
                }
            }
        }
    }

    func disconnect() {
        guard isConnected || isBusy == false else { return }
        isBusy = true
        statusText = "正在断开…"

        Task.detached { [weak self] in
            let errMsg: String? = {
                do { try OpenConnectRunner.cleanup(); return nil }
                catch { return error.localizedDescription }
            }()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isBusy = false
                self.isConnected = false
                self.statusText = errMsg ?? "未连接"
            }
        }
    }

    // MARK: - Sudo helpers

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
                if let errMsg { self.statusText = errMsg }
                else if !self.isConnected { self.statusText = "未连接" }
                // 装完之后立刻跑一次 cleanup，顺手把 v0.2 残余（如果有）也清了
                if self.sudoConfigured {
                    self.runCleanupDetached(reason: "安装后首次清理")
                }
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

    // MARK: - Polling

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollTick()
            }
        }
    }

    private func pollTick() {
        let running = OpenConnectRunner.isRunning
        // 声明"连着"但 openconnect 没了 = 意外死亡 → 自动 cleanup
        if isConnected, !running, !isBusy {
            isBusy = true
            statusText = "连接已丢失，正在清理…"
            runCleanupDetached(reason: "意外断开自动清理") { [weak self] in
                self?.isConnected = false
                self?.isBusy = false
                self?.statusText = "未连接"
            }
        }
    }

    // MARK: - Sleep hook

    private func registerSleepHook() {
        let nc = NSWorkspace.shared.notificationCenter
        sleepObserver = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWillSleep()
            }
        }
        wakeObserver = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleDidWake()
            }
        }
    }

    private func handleWillSleep() {
        // willSleep 通知给应用 ~20s 窗口。cleanup 最多 12s，够用。
        // 只在确实连着 + sudo 已配 的情况下清；其他情况 noop 就行。
        shouldReconnectAfterWake = isConnected
        guard sudoConfigured, isConnected || OpenConnectRunner.isRunning else { return }
        // 同步跑（阻塞主线程，屏幕要黑掉了 UI 阻塞无所谓）
        try? OpenConnectRunner.cleanup()
        isConnected = false
        statusText = "未连接"
    }

    private func handleDidWake() {
        // 唤醒后 openconnect 进程可能还活着，但 VPN 服务端 session 已超时、
        // TLS/DTLS 连接已断，隧道实际是黑洞。进程活着 ≠ 隧道通。
        // 先 cleanup 清残留，再根据睡前状态决定是否自动重连。
        let shouldReconnect = shouldReconnectAfterWake
        shouldReconnectAfterWake = false

        guard sudoConfigured else { return }

        if isConnected || OpenConnectRunner.isRunning {
            isBusy = true
            statusText = "休眠唤醒，正在清理…"
            runCleanupDetached(reason: "唤醒后清理残留隧道") { [weak self] in
                guard let self else { return }
                self.isConnected = false
                self.isBusy = false
                self.statusText = "未连接"
                if shouldReconnect { self.reconnectAfterWake() }
            }
        } else if shouldReconnect {
            // willSleep 已经清干净了，直接重连
            reconnectAfterWake()
        }
    }

    /// 唤醒后自动重连。需要凭据齐全才尝试，否则静默跳过（用户手动点连接就行）。
    private func reconnectAfterWake() {
        guard !server.isEmpty, !user.isEmpty, !password.isEmpty else {
            statusText = "未连接（缺少凭据，请手动连接）"
            return
        }
        statusText = "正在自动重连…"
        connect()
    }

    // MARK: - Internal helpers

    /// 在后台跑 cleanup，成功/失败都更新一下 isConnected / statusText。
    private func runCleanupDetached(
        reason: String,
        completion: (@MainActor () -> Void)? = nil
    ) {
        Task.detached { [weak self] in
            try? OpenConnectRunner.cleanup()
            await MainActor.run { [weak self] in
                guard let self else { return }
                // 不改 isBusy —— 启动期间的 cleanup 是静默的，不应该锁 UI
                if let completion { completion() }
                else {
                    // 没 completion → 静默 cleanup，不改 statusText
                    // 只在真的已经不跑了的情况下确认 isConnected
                    if !OpenConnectRunner.isRunning, self.isConnected {
                        self.isConnected = false
                        self.statusText = "未连接"
                    }
                }
                _ = reason  // 目前不输出日志，保留参数便于后续加 os_log
            }
        }
    }
}
