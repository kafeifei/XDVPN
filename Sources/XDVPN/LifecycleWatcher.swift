import AppKit
import Foundation
import Network

/// 监听系统睡眠、唤醒、网络路径变化，通知 VPNController 做对应处理。
/// 核心目的：合盖换网络后，openconnect 的 utun 默认路由不会残留。
@MainActor
final class LifecycleWatcher {
    private weak var controller: VPNController?
    private var observers: [NSObjectProtocol] = []
    private let pathMonitor = NWPathMonitor()
    private var lastPathDescription: String = ""

    init(controller: VPNController) {
        self.controller = controller
        registerSleepWake()
        startPathMonitor()
    }

    deinit {
        let obs = observers
        let nc = NSWorkspace.shared.notificationCenter
        for o in obs { nc.removeObserver(o) }
        pathMonitor.cancel()
    }

    private func registerSleepWake() {
        let nc = NSWorkspace.shared.notificationCenter

        // 合盖 / 系统睡眠前：这是干净断开的唯一时机（此时旧 Wi-Fi 还在）
        observers.append(
            nc.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleWillSleep() }
            }
        )

        // 唤醒：校验状态，检测异常
        observers.append(
            nc.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleDidWake() }
            }
        )
    }

    private func handleWillSleep() {
        guard let c = controller, c.isConnected else { return }
        // 同步阻塞最多 12 秒等 vpnc-script 回收路由。
        // willSleepNotification 给应用 ~20 秒准备时间，够用。
        c.disconnectForSleep()
    }

    private func handleDidWake() {
        controller?.refreshAfterWake()
    }

    // MARK: - Network path monitoring

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handlePathChange(path)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "xdvpn.path"))
    }

    private func handlePathChange(_ path: NWPath) {
        // 先把"当前是否有可达路径"传给 AR，让它判断是否等网
        controller?.networkReachabilityChanged(path.status == .satisfied)

        // 用非 utun 物理接口名列表作为"路径指纹"
        let desc = path.availableInterfaces.map { $0.name }.sorted().joined(separator: ",")
        defer { lastPathDescription = desc }

        // 首次回调跳过（刚启动，无"变化"可言）
        if lastPathDescription.isEmpty { return }
        if desc == lastPathDescription { return }

        guard let c = controller, c.isConnected else { return }
        // 非 utun 物理接口集合发生变化 = 换网了 —— VPN 肯定废了，干净重建
        let before = Set(lastPathDescription.split(separator: ",").filter { !$0.hasPrefix("utun") })
        let after = Set(desc.split(separator: ",").filter { !$0.hasPrefix("utun") })
        if before != after && !after.isEmpty {
            c.networkChangedWhileConnected()
        }
    }
}
