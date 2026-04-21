import Foundation
import SwiftUI

@MainActor
final class VPNController: ObservableObject {
    @Published var protocolName: String = "anyconnect"
    @Published var server: String = ""
    @Published var user: String = ""
    @Published var password: String = ""
    @Published var rememberPassword: Bool = true

    @Published var isConnected: Bool = false
    @Published var isBusy: Bool = false
    @Published var statusText: String = "未连接"
    @Published var sudoConfigured: Bool = SudoersInstaller.isInstalled

    private var pollTimer: Timer?

    init() {
        loadPrefs()
        isConnected = OpenConnectRunner.isRunning
        statusText = isConnected ? "已连接" : "未连接"
        if isConnected { startPolling() }
    }

    var canConnect: Bool {
        !server.isEmpty && !user.isEmpty && !password.isEmpty
            && !isBusy && !isConnected
    }

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

    private var keychainAccount: String { "\(user)@\(server)" }

    func connect() {
        guard canConnect else { return }
        isBusy = true
        statusText = "正在连接…"
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
                    BiometricGate.markActivity()   // 连接成功 = 一次有效活动，刷新 7 天窗口
                    self.isConnected = true
                    self.statusText = "已连接"
                    self.isBusy = false
                    self.startPolling()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isBusy = false
                    self.isConnected = false
                    self.statusText = error.localizedDescription
                    if case VPNError.sudoNotConfigured = error {
                        self.sudoConfigured = false
                    }
                }
            }
        }
    }

    func disconnect() {
        isBusy = true
        statusText = "正在断开…（等 openconnect 回收路由）"
        Task.detached { [weak self] in
            let errMsg: String?
            do {
                try OpenConnectRunner.disconnect()
                errMsg = nil
            } catch {
                errMsg = error.localizedDescription
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                let stillRunning = OpenConnectRunner.isRunning
                self.isConnected = stillRunning
                if let errMsg {
                    self.statusText = errMsg
                } else {
                    self.statusText = stillRunning ? "断开超时" : "未连接"
                }
                self.isBusy = false
                if !stillRunning { self.stopPolling() }
            }
        }
    }

    func installSudoers() {
        isBusy = true
        Task.detached { [weak self] in
            let errMsg: String?
            do {
                try SudoersInstaller.install()
                errMsg = nil
            } catch {
                errMsg = error.localizedDescription
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isBusy = false
                self.sudoConfigured = SudoersInstaller.isInstalled
                if let errMsg { self.statusText = errMsg }
                else { self.statusText = self.isConnected ? "已连接" : "未连接" }
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

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let running = OpenConnectRunner.isRunning
                if self.isConnected && !running {
                    self.isConnected = false
                    self.statusText = "连接已断开"
                    self.stopPolling()
                }
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
