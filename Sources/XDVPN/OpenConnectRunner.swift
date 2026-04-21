import Foundation

enum VPNError: LocalizedError {
    case openconnectNotFound
    case invalidProtocol
    case connectFailed(String)
    case sudoNotConfigured
    case disconnectStuck

    var errorDescription: String? {
        switch self {
        case .openconnectNotFound: return "未找到 openconnect，请先 brew install openconnect"
        case .invalidProtocol: return "不支持的协议"
        case .connectFailed(let s): return "连接失败：\(s)"
        case .sudoNotConfigured: return "sudo 免密未配置或规则不完整，请重新点击\"一键配置\""
        case .disconnectStuck: return "openconnect 断开超时，路由可能未回收 — 查看终端输出或重启 Wi-Fi"
        }
    }
}

enum OpenConnectRunner {
    static let pidPath = "/tmp/xdvpn.pid"
    static let logPath = "/tmp/xdvpn.log"

    /// 固定路径，安装时由 SudoersInstaller 以 root 写入，用户无写权限，
    /// 所以把它加进 sudoers NOPASSWD 是安全的。
    static let stopHelperPath = "/usr/local/libexec/xdvpn-stop"

    static let protocols = ["anyconnect", "nc", "gp", "pulse", "f5", "fortinet", "array"]

    static var openconnectPath: String? {
        for p in ["/opt/homebrew/bin/openconnect", "/usr/local/bin/openconnect"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func connect(
        protocolName: String,
        server: String,
        user: String,
        password: String
    ) throws {
        guard protocols.contains(protocolName) else { throw VPNError.invalidProtocol }
        guard let ocPath = openconnectPath else { throw VPNError.openconnectNotFound }

        try? FileManager.default.removeItem(atPath: pidPath)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        // 重要：不再用 --setuid。openconnect 必须保持 root 身份，
        // 否则收到 SIGTERM 时没权限跑 vpnc-script 回收路由,会把默认路由留在一个
        // 已经消失的 utun 接口上,导致全局断网。
        proc.arguments = [
            "-n",
            ocPath,
            "--background",
            "--pid-file=" + pidPath,
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
        proc.standardOutput = FileHandle(forWritingAtPath: logPath)
            ?? { FileManager.default.createFile(atPath: logPath, contents: nil)
                 return FileHandle(forWritingAtPath: logPath)! }()

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
            if msg.contains("a password is required")
                || msg.contains("sudo:")
                || msg.contains("no tty present")
            {
                throw VPNError.sudoNotConfigured
            }
            throw VPNError.connectFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// 通过 sudoers NOPASSWD 允许的 root-owned helper 发 SIGTERM，
    /// 等 vpnc-script 清理完路由再返回。若 15 秒仍没清完，抛错但**不强杀**，
    /// 避免 SIGKILL 跳过 vpnc-script 导致路由残留。
    static func disconnect() throws {
        guard let pid = currentPid() else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        proc.arguments = ["-n", stopHelperPath]
        let errPipe = Pipe()
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            throw VPNError.connectFailed(error.localizedDescription)
        }

        // 等进程真正退出（最多 15s，vpnc-script 需要时间）
        for _ in 0..<150 {
            if !isAlive(pid) { break }
            usleep(100_000)
        }
        if isAlive(pid) {
            throw VPNError.disconnectStuck
        }
        try? FileManager.default.removeItem(atPath: pidPath)
    }

    static func currentPid() -> pid_t? {
        guard let s = try? String(contentsOfFile: pidPath, encoding: .utf8) else { return nil }
        return pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        return kill(pid, 0) == 0 || errno == EPERM
    }

    static var isRunning: Bool {
        guard let pid = currentPid() else { return false }
        return isAlive(pid)
    }
}
