import Foundation

enum VPNError: LocalizedError {
    case openconnectNotFound
    case invalidProtocol
    case connectFailed(String)
    case sudoNotConfigured
    case cleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .openconnectNotFound: return "安装包缺少内置 openconnect，请重新下载 XDVPN"
        case .invalidProtocol: return "不支持的协议"
        case .connectFailed(let s): return "连接失败：\(s)"
        case .sudoNotConfigured: return "sudo 免密未配置或规则不完整，请重新点击\"一键配置\""
        case .cleanupFailed(let s): return "清理失败：\(s)"
        }
    }
}

/// 封装 openconnect 进程的生命周期。
/// v0.3 相比 v0.2 的关键变化：
/// 1) 用 `--script=xdvpn-route-script` 替代默认 vpnc-script
///    → 路由改用 def1 技巧，系统原有 default route 永远不被碰
/// 2) 不再 save/restore 原网关；cleanup 只删我们自己加过的东西
/// 3) disconnect == cleanup，完全同一段代码（跑 xdvpn-cleanup helper）
///    → 没有"修复路由"的概念，也没有分叉路径
enum OpenConnectRunner {
    /// openconnect 写的 pid 文件（/tmp，reboot 持久但 3 天无访问会被 periodic 清）
    static let pidPath = "/tmp/xdvpn.pid"
    /// 纯代理模式独立 pid 文件（无 sudo，user-owned）
    static let proxyModePidPath = "/tmp/xdvpn-proxy.pid"

    static let protocols = ["anyconnect", "nc", "gp", "pulse", "f5", "fortinet", "array"]

    // MARK: - Connect

    /// 启动 openconnect。--background 让它在建好隧道、跑完 route-script 之后再 fork。
    /// 所以本函数返回 = 连接已建立 + session.state 已写好。
    /// 调用线程：**不要**在 MainActor 上跑（会阻塞 UI）。
    static func connect(
        protocolName: String,
        server: String,
        user: String,
        password: String
    ) throws {
        guard protocols.contains(protocolName) else { throw VPNError.invalidProtocol }
        // 清掉可能残留的旧 pid 文件（openconnect 会创建新的，但防御一下）
        try? FileManager.default.removeItem(atPath: pidPath)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        // 所有参数由 arguments 传入，不经 shell，密码不会被日志捕获。
        // sudoers 只放行 xdvpn-openconnect wrapper，wrapper 固定 openconnect 参数。
        proc.arguments = [
            "-n", // 非交互；sudoers 没配会立刻失败
            SudoersInstaller.openconnectWrapperPath,
            "--protocol", protocolName,
            "--user", user,
            "--server",
            server,
        ]

        let stdin = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardError = stderr
        // 不接 stdout —— openconnect 自己写 syslog，我们不需要另一份 log 文件

        do {
            try proc.run()
        } catch {
            throw VPNError.connectFailed(error.localizedDescription)
        }

        stdin.fileHandleForWriting.write(Data((password + "\n").utf8))
        try? stdin.fileHandleForWriting.close()

        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8) ?? "exit \(proc.terminationStatus)"
            // sudo 拒绝 → 免密未配置
            if msg.contains("a password is required")
                || msg.contains("sudo:")
                || msg.contains("no tty present")
            {
                throw VPNError.sudoNotConfigured
            }
            throw VPNError.connectFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Cleanup（== Disconnect）

    /// 调 xdvpn-cleanup：停我们的 openconnect、清我们 session 里记下的一切。
    /// 幂等、安全、可在任何时机反复调（启动时 / 用户点断开 / 合盖前）。
    /// 调用线程：不要在 MainActor（阻塞最多 ~12s 等 vpnc-script 回收）。
    static func cleanup() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        proc.arguments = ["-n", SudoersInstaller.cleanupPath]
        let errPipe = Pipe()
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            throw VPNError.cleanupFailed(error.localizedDescription)
        }
        if proc.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg =
                String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "exit \(proc.terminationStatus)"
            throw VPNError.cleanupFailed(msg.isEmpty ? "exit \(proc.terminationStatus)" : msg)
        }
    }

    /// disconnect 和 cleanup 是完全同义的。提供别名让调用方代码更易读。
    static func disconnect() throws { try cleanup() }

    // MARK: - 纯代理模式 (userspace, no sudo)
    //
    // openconnect --script-tun --script "ocproxy -D <port>" ...
    //   - 不创建 utun → 不需要 sudo
    //   - openconnect 把 IP 包通过 pipe 喂给 ocproxy
    //   - ocproxy 用 lwIP 在用户态实现 TCP/IP 栈，暴露 SOCKS5
    //   - 完全不动 macOS 路由表 / DNS resolver / 任何系统状态

    /// 在 app bundle 里找 ocproxy，或回退到 brew 安装
    static func locateOcproxy() -> String? {
        if let resourcePath = Bundle.main.resourcePath {
            let bundled = resourcePath + "/openconnect/bin/ocproxy"
            if FileManager.default.isExecutableFile(atPath: bundled) {
                return bundled
            }
        }
        for path in ["/opt/homebrew/bin/ocproxy", "/usr/local/bin/ocproxy"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// 在 app bundle 里找 openconnect
    static func locateBundledOpenconnect() -> String? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let path = resourcePath + "/openconnect/bin/openconnect"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// 启动纯代理模式：openconnect + ocproxy，user 身份，无 sudo。
    /// 调用线程：**不要** MainActor（同步阻塞等到 connect 完成）
    static func connectProxyMode(
        protocolName: String,
        server: String,
        user: String,
        password: String,
        socksPort: UInt16
    ) throws {
        guard protocols.contains(protocolName) else { throw VPNError.invalidProtocol }

        guard let openconnectBin = locateBundledOpenconnect() else {
            throw VPNError.connectFailed("找不到 bundled openconnect")
        }
        guard let ocproxyBin = locateOcproxy() else {
            throw VPNError.connectFailed("找不到 ocproxy。请 brew install ocproxy，或重新打包 app")
        }

        // 清掉旧 pid 文件（防御性）
        try? FileManager.default.removeItem(atPath: proxyModePidPath)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: openconnectBin)
        proc.arguments = [
            "--background",
            // 客户端每 5s 主动 DPD 探死链：服务端 idle 踢会话 / DTLS 假死后秒级被发现，
            // openconnect 自愈失败即退出，pollTick 的进程探活随即接管重连。零 sudo 代价（user 态）。
            "--force-dpd=5",
            "--pid-file=" + proxyModePidPath,
            "--script-tun",
            // openconnect 通过 sh -c 执行 script string，所以 ocproxy 路径要 quote
            "--script", "'\(ocproxyBin)' -D \(socksPort)",
            "--protocol", protocolName,
            "--user", user,
            server,
        ]

        let stdin = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardError = stderr

        do {
            try proc.run()
        } catch {
            throw VPNError.connectFailed(error.localizedDescription)
        }

        stdin.fileHandleForWriting.write(Data((password + "\n").utf8))
        try? stdin.fileHandleForWriting.close()

        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8) ?? "exit \(proc.terminationStatus)"
            throw VPNError.connectFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// 断开纯代理模式：kill openconnect + ocproxy
    /// 现实里 openconnect 死了 ocproxy 不一定跟着死（pipe 闭了 ocproxy 也可能继续 listen），
    /// 所以两个都得显式清掉
    static func disconnectProxyMode() {
        // 1) 拿 openconnect 的 pid 从 pid-file 中
        let ocPid: pid_t? = {
            guard let s = try? String(contentsOfFile: proxyModePidPath, encoding: .utf8) else { return nil }
            return pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines))
        }()
        if let pid = ocPid {
            killAndWait(pid)
        }

        // 2) 兜底：找孤儿 ocproxy 和 openconnect。**只匹配 bundle 里的绝对路径**，
        //    避免误杀用户在别处装的 ocproxy / openconnect。
        //    Bundle 路径形如 `XDVPN.app/Contents/Resources/openconnect/bin/<bin>`，
        //    用 pgrep 的全路径匹配既能精确锁定我们启的进程，又能跨多份 .app 安装（如 dev + 生产）。
        if let resourcePath = Bundle.main.resourcePath {
            let ocproxyPath = resourcePath + "/openconnect/bin/ocproxy"
            let openconnectPath = resourcePath + "/openconnect/bin/openconnect"
            for pid in pidsMatching(command: ocproxyPath) { killAndWait(pid) }
            for pid in pidsMatching(command: openconnectPath) { killAndWait(pid) }
        }

        try? FileManager.default.removeItem(atPath: proxyModePidPath)
    }

    private static func killAndWait(_ pid: pid_t) {
        kill(pid, SIGTERM)
        for _ in 0..<20 {  // 最多 2s
            if kill(pid, 0) != 0 { break }
            usleep(100_000)
        }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    /// 用 `pgrep -f <pattern>` 找匹配命令行的 pid
    private static func pidsMatching(command: String) -> [pid_t] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-f", command]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch { return [] }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 != ProcessInfo.processInfo.processIdentifier }  // 不杀自己
    }

    static var proxyModePid: pid_t? {
        guard let s = try? String(contentsOfFile: proxyModePidPath, encoding: .utf8) else { return nil }
        return pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static var isProxyModeRunning: Bool {
        guard let pid = proxyModePid else { return false }
        return isAlive(pid)
    }

    // MARK: - Status query

    static func currentPid() -> pid_t? {
        guard let s = try? String(contentsOfFile: pidPath, encoding: .utf8) else { return nil }
        return pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        // kill 0 不发信号，只校验是否有权（EPERM 也算活着，只是非本用户）
        return kill(pid, 0) == 0 || errno == EPERM
    }

    static var isRunning: Bool {
        guard let pid = currentPid() else { return false }
        return isAlive(pid)
    }
}
