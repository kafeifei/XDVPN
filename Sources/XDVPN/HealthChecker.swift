import Foundation

/// 当前真实系统状态的快照，由 HealthChecker.sample() 采集。
/// 只描述事实（"此刻系统长这样"），不做诊断。诊断由 VPNController 做，
/// 因为只有它知道我们"声称"连上没有。
struct SystemState {
    /// /tmp/xdvpn.pid 里存的 openconnect PID（nil = 文件不存在或解析失败）
    let savedPid: pid_t?
    /// savedPid 指向的进程此刻是否存活
    let pidAlive: Bool
    /// 此刻有 inet/inet6 地址的 utun 接口名（排序），例如 ["utun4"]
    let utunInterfaces: [String]
    /// 当前默认路由走的接口名：typical "en0" / "utun4" / nil（没有默认路由）
    let defaultRouteInterface: String?
    /// 当前默认路由的网关 IP，例如 "192.168.0.1"。utun 路由这里通常是对端点地址。
    let defaultRouteGateway: String?

    var hasUtunDefaultRoute: Bool {
        defaultRouteInterface?.hasPrefix("utun") ?? false
    }

    var hasAnyDefaultRoute: Bool {
        defaultRouteInterface != nil
    }
}

/// 1 秒一次的心跳采样。所有操作都是同步短命调用，不会卡主线程明显耗时。
/// 设计目标：这一层 **只**报告事实，绝不修改系统状态；让决策层纯粹可测。
enum HealthChecker {
    /// 采一次快照。每秒调 1 次。冷启动时第一个 tick 就能发现上次崩溃留下的残局。
    static func sample() -> SystemState {
        let pid = OpenConnectRunner.currentPid()
        let alive = pid.map { OpenConnectRunner.isAlive($0) } ?? false
        let (iface, gw) = readDefaultRoute()
        return SystemState(
            savedPid: pid,
            pidAlive: alive,
            utunInterfaces: findActiveUtunInterfaces(),
            defaultRouteInterface: iface,
            defaultRouteGateway: gw
        )
    }

    /// 遍历 `getifaddrs` 找所有叫 utun* 且至少有一个 inet/inet6 地址的接口。
    /// 没地址的 utun 不算"激活"；openconnect 拆管子时接口会先丢地址再消失。
    private static func findActiveUtunInterfaces() -> [String] {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let head = ifap else { return [] }
        defer { freeifaddrs(head) }

        var found = Set<String>()
        var cur: UnsafeMutablePointer<ifaddrs>? = head
        while let p = cur {
            let name = String(cString: p.pointee.ifa_name)
            if name.hasPrefix("utun"), let sa = p.pointee.ifa_addr {
                let fam = sa.pointee.sa_family
                if fam == sa_family_t(AF_INET) || fam == sa_family_t(AF_INET6) {
                    found.insert(name)
                }
            }
            cur = p.pointee.ifa_next
        }
        return found.sorted()
    }

    /// 同步调用 `/sbin/route -n get default`，解析出 interface / gateway 行。
    /// 典型 5-15ms；1Hz 频率完全可以承受。
    private static func readDefaultRoute() -> (iface: String?, gateway: String?) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/sbin/route")
        proc.arguments = ["-n", "get", "default"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return (nil, nil) }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return (nil, nil) }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return (nil, nil) }

        var iface: String?
        var gw: String?
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let r = t.range(of: "interface:") {
                iface = t[r.upperBound...].trimmingCharacters(in: .whitespaces)
            } else if let r = t.range(of: "gateway:") {
                gw = t[r.upperBound...].trimmingCharacters(in: .whitespaces)
            }
        }
        return (iface, gw)
    }
}

/// VPNController 对一次心跳采样给出的诊断。
/// 命名有意直白：方便 UI 层按 case 映射到用户文案。
enum HealthVerdict: Equatable {
    /// 自称连着 + 系统也确实在 VPN 上（utun 默认路由、openconnect 还活着）
    case healthyConnected
    /// 自称没连 + 系统也确实没连 + 无残留
    case healthyDisconnected
    /// pid 文件在，但进程死了 —— openconnect 崩溃或被 kill
    case openconnectDied
    /// pid 活着，但默认路由不是 utun —— 合盖换网后路由被顶掉，需要强制重连
    case routeEscaped
    /// 无 pid 文件，但还有 utun 默认路由 —— 疑似上次崩溃的残局，需要修复
    case ghostRoute
    /// 未声明连接，但默认路由读不到 —— 极可能是物理网断了（非 VPN 问题）
    case networkDown
}

extension HealthChecker {
    /// 对事实做诊断。放在这里而不是 Controller 是为了纯函数可测。
    static func diagnose(declaredConnected: Bool, state: SystemState) -> HealthVerdict {
        if declaredConnected {
            // 我们认为连着
            if state.savedPid != nil, !state.pidAlive {
                return .openconnectDied
            }
            // pid 文件没了但声明已连 = 被外部清理 pid 文件，当作死亡处理
            if state.savedPid == nil { return .openconnectDied }

            // 进程还在 —— 核对默认路由
            if state.hasUtunDefaultRoute { return .healthyConnected }
            // 读不到默认路由但 pid 活着：可能刚切网、还在 renegotiate —— 等下次心跳再判
            if !state.hasAnyDefaultRoute { return .healthyConnected }
            return .routeEscaped
        } else {
            // 未声明连接
            if state.savedPid != nil && state.pidAlive {
                // 死 pid 文件保留，进程却在？罕见 —— 当作异常让 Controller 清理
                return .ghostRoute
            }
            if state.hasUtunDefaultRoute {
                // 只要默认路由还走 utun，就是残留 —— 不管 pid 文件在不在
                return .ghostRoute
            }
            if !state.hasAnyDefaultRoute {
                return .networkDown
            }
            return .healthyDisconnected
        }
    }
}
