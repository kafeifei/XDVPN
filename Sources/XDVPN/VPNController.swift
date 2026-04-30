import AppKit
import Darwin.POSIX.net
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

    // MARK: - 分流（Split Tunnel）
    /// 开关：打开 → 只把勾选/自定义的子网路由进 VPN；关 → def1 全流量
    @Published var splitEnabled: Bool = false
    @Published var splitPreset10: Bool = true      // 10.0.0.0/8
    @Published var splitPreset172: Bool = true     // 172.16.0.0/12
    @Published var splitPreset192: Bool = false    // 192.168.0.0/16（通常是本地 LAN）
    /// 自定义 CIDR，多行/逗号分隔
    @Published var splitCustom: String = ""
    /// 域名分流后缀列表，一行一个（如 xindong.com），匹配该域名及所有子域名
    @Published var splitDomains: String = ""

    // MARK: - 状态

    @Published private(set) var isConnected: Bool = false
    @Published private(set) var isBusy: Bool = false
    @Published private(set) var statusText: String = "未连接"
    @Published private(set) var sudoConfigured: Bool = SudoersInstaller.isInstalled

    // MARK: - 诊断信息

    @Published private(set) var connectedAt: Date?
    @Published private(set) var tunnelInterface: String?
    @Published private(set) var tunnelIP: String?
    @Published private(set) var vpnGateway: String?
    @Published private(set) var activeRoutes: [String] = []
    @Published private(set) var dnsProxyActive: Bool = false
    @Published private(set) var trafficIn: UInt64 = 0
    @Published private(set) var trafficOut: UInt64 = 0

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
        d.set(splitEnabled, forKey: "xdvpn.split.enabled")
        d.set(splitPreset10, forKey: "xdvpn.split.preset10")
        d.set(splitPreset172, forKey: "xdvpn.split.preset172")
        d.set(splitPreset192, forKey: "xdvpn.split.preset192")
        d.set(splitCustom, forKey: "xdvpn.split.custom")
        d.set(splitDomains, forKey: "xdvpn.split.domains")
    }

    private func loadPrefs() {
        let d = UserDefaults.standard
        protocolName = d.string(forKey: "xdvpn.protocol") ?? "anyconnect"
        server = d.string(forKey: "xdvpn.server") ?? ""
        user = d.string(forKey: "xdvpn.user") ?? ""
        rememberPassword = d.object(forKey: "xdvpn.remember") as? Bool ?? true
        splitEnabled = d.object(forKey: "xdvpn.split.enabled") as? Bool ?? false
        splitPreset10 = d.object(forKey: "xdvpn.split.preset10") as? Bool ?? true
        splitPreset172 = d.object(forKey: "xdvpn.split.preset172") as? Bool ?? true
        splitPreset192 = d.object(forKey: "xdvpn.split.preset192") as? Bool ?? false
        splitCustom = d.string(forKey: "xdvpn.split.custom") ?? ""
        splitDomains = d.string(forKey: "xdvpn.split.domains") ?? ""
        if rememberPassword, !user.isEmpty, !server.isEmpty {
            password = KeychainStore.load(account: keychainAccount) ?? ""
        }
    }

    // MARK: - 分流

    nonisolated static let splitConfPath = "/tmp/xdvpn-split.conf"
    nonisolated static let domainConfPath = "/tmp/xdvpn-split-domains.conf"

    /// 按当前 UI 状态收集并校验 CIDR。非法的静默丢弃。
    func collectSplitCIDRs() -> [String] {
        var out: [String] = []
        if splitPreset10 { out.append("10.0.0.0/8") }
        if splitPreset172 { out.append("172.16.0.0/12") }
        if splitPreset192 { out.append("192.168.0.0/16") }

        let extras = splitCustom
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter(Self.isValidCIDR)
        out.append(contentsOf: extras)

        // 去重，保持顺序
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    func collectDomainSuffixes() -> [String] {
        var seen = Set<String>()
        return splitDomains
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .map { $0.hasPrefix("*.") ? String($0.dropFirst(2)) : $0 }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && Self.isValidDomainSuffix($0) }
            .filter { seen.insert($0).inserted }
    }

    private static func isValidDomainSuffix(_ s: String) -> Bool {
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
                && !label.hasPrefix("-") && !label.hasSuffix("-")
        }
    }

    /// 基础 CIDR 语法校验：X.X.X.X/N，N∈[0,32]，四段 0–255。
    private static func isValidCIDR(_ s: String) -> Bool {
        let parts = s.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let maskLen = Int(parts[1]),
              (0...32).contains(maskLen) else { return false }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { seg in
            if let n = Int(seg), (0...255).contains(n) { return true }
            return false
        }
    }

    /// 供 detached task 调用（非 MainActor）。enabled=false 或 cidrs 为空 → 删除旧文件。
    nonisolated static func writeSplitConfFile(enabled: Bool, cidrs: [String]) {
        let path = splitConfPath
        if enabled, !cidrs.isEmpty {
            let content = cidrs.joined(separator: "\n") + "\n"
            try? content.write(toFile: path, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    nonisolated static func writeDomainConfFile(enabled: Bool, domains: [String]) {
        let path = domainConfPath
        if enabled, !domains.isEmpty {
            let content = domains.joined(separator: "\n") + "\n"
            try? content.write(toFile: path, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(atPath: path)
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
        let splitOn = splitEnabled
        let splitCIDRs = collectSplitCIDRs()
        let domainSuffixes = collectDomainSuffixes()

        Task.detached { [weak self] in
            // 先 cleanup 确保干净起点（即使启动时跑过，用户可能在期间手动 kill 过什么）
            try? OpenConnectRunner.cleanup()

            // cleanup 会删 split conf；现在按当前 UI 状态重新写一遍
            // 必须在 openconnect 启动之前，让路由脚本能读到
            Self.writeSplitConfFile(enabled: splitOn, cidrs: splitCIDRs)
            Self.writeDomainConfFile(enabled: splitOn, domains: domainSuffixes)

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
                    self.connectedAt = Date()
                    self.parseSessionFile()
                    self.updateTrafficStats()
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
                self.clearDiagnostics()
                self.statusText = errMsg ?? "未连接"
            }
        }
    }

    // MARK: - Sudo helpers

    func installSudoers(thenConnect: Bool = false) {
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
                // 配置成功 + 凭据齐全 → 自动连接
                if thenConnect, self.canConnect {
                    self.connect()
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
        if isConnected, running {
            if tunnelInterface == nil { parseSessionFile() }
            updateTrafficStats()
        }
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
        clearDiagnostics()
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

    // MARK: - 诊断数据采集

    private func parseSessionFile() {
        guard let content = try? String(contentsOfFile: "/tmp/xdvpn.session", encoding: .utf8) else { return }
        var routes: [String] = []
        var hasDnsProxy = false
        for line in content.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            switch String(parts[0]) {
            case "TUNDEV": tunnelInterface = String(parts[1])
            case "VPNGATEWAY": vpnGateway = String(parts[1])
            case "ROUTE_NET": routes.append(String(parts[1]))
            case "DNS_PROXY_PID": hasDnsProxy = true
            default: break
            }
        }
        activeRoutes = routes
        dnsProxyActive = hasDnsProxy
    }

    private func updateTrafficStats() {
        guard let iface = tunnelInterface else { return }
        let info = Self.queryTunnel(iface)
        tunnelIP = info.ip
        trafficIn = info.bytesIn
        trafficOut = info.bytesOut
    }

    private func clearDiagnostics() {
        connectedAt = nil
        tunnelInterface = nil
        tunnelIP = nil
        vpnGateway = nil
        activeRoutes = []
        dnsProxyActive = false
        trafficIn = 0
        trafficOut = 0
    }

    struct TunnelInfo {
        var ip: String?
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
    }

    nonisolated static func queryTunnel(_ name: String) -> TunnelInfo {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return TunnelInfo() }
        defer { freeifaddrs(first) }

        var info = TunnelInfo()
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cur {
            defer { cur = ifa.pointee.ifa_next }
            guard String(cString: ifa.pointee.ifa_name) == name,
                  let addr = ifa.pointee.ifa_addr else { continue }

            let family = Int32(addr.pointee.sa_family)
            if family == AF_INET {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                            &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
                info.ip = String(cString: buf)
            }
            if family == AF_LINK, let data = ifa.pointee.ifa_data {
                let d = data.assumingMemoryBound(to: if_data.self).pointee
                info.bytesIn = UInt64(d.ifi_ibytes)
                info.bytesOut = UInt64(d.ifi_obytes)
            }
        }
        return info
    }

    var diagnosticsSummary: String {
        var lines: [String] = []
        lines.append("XDVPN 连接诊断")
        lines.append("协议\t\(protocolName)")
        lines.append("服务器\t\(server)")
        if let gw = vpnGateway { lines.append("网关\t\(gw)") }
        if let iface = tunnelInterface { lines.append("接口\t\(iface)") }
        if let ip = tunnelIP { lines.append("地址\t\(ip)") }
        if let t = connectedAt {
            let dur = Int(Date().timeIntervalSince(t))
            lines.append("时长\t\(Self.formatDuration(dur))")
        }
        lines.append("流量\t↑ \(Self.formatBytes(trafficOut))  ↓ \(Self.formatBytes(trafficIn))")
        if !activeRoutes.isEmpty { lines.append("路由\t\(activeRoutes.joined(separator: ", "))") }
        lines.append("分流\t\(splitEnabled ? "启用" : "关闭")")
        if dnsProxyActive { lines.append("DNS 代理\t活跃") }
        return lines.joined(separator: "\n")
    }

    nonisolated static func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    nonisolated static func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var idx = 0
        while value >= 1024 && idx < units.count - 1 { value /= 1024; idx += 1 }
        return idx == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[idx])
    }

    // MARK: - Internal helpers

    /// 在后台跑 cleanup，成功/失败都更新一下 isConnected / statusText。
    private func runCleanupDetached(
        reason: String,
        completion: (@MainActor () -> Void)? = nil
    ) {
        Task.detached { [weak self] in
            try? OpenConnectRunner.cleanup()
            // 兜底：cleanup helper 里也删了，这里再来一次无害
            try? FileManager.default.removeItem(atPath: Self.splitConfPath)
            try? FileManager.default.removeItem(atPath: Self.domainConfPath)
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
