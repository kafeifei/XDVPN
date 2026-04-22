import Foundation

enum VPNError: LocalizedError {
    case openconnectNotFound
    case invalidProtocol
    case connectFailed(String)
    case sudoNotConfigured
    case cleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .openconnectNotFound: return "未找到 openconnect，请先 brew install openconnect"
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

    static let protocols = ["anyconnect", "nc", "gp", "pulse", "f5", "fortinet", "array"]

    /// 在 Apple Silicon 和 Intel 两种 Homebrew 前缀中找
    static var openconnectPath: String? {
        for p in ["/opt/homebrew/bin/openconnect", "/usr/local/bin/openconnect"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

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
        guard let ocPath = openconnectPath else { throw VPNError.openconnectNotFound }

        // 清掉可能残留的旧 pid 文件（openconnect 会创建新的，但防御一下）
        try? FileManager.default.removeItem(atPath: pidPath)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        // 所有参数由 arguments 传入，不经 shell，密码不会被日志捕获。
        // 不用 --setuid：openconnect 必须保持 root 才能让我们的 script 动路由。
        proc.arguments = [
            "-n",                                            // 非交互；sudoers 没配会立刻失败
            ocPath,
            "--background",
            "--pid-file=" + pidPath,
            "--script=" + SudoersInstaller.routeScriptPath,  // 关键：替换 vpnc-script
            "--protocol=" + protocolName,
            "--passwd-on-stdin",
            "--user=" + user,
            "--non-inter",
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
