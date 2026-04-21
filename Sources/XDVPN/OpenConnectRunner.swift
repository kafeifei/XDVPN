import Foundation

enum VPNError: LocalizedError {
    case openconnectNotFound
    case invalidProtocol
    case connectFailed(String)
    case sudoNotConfigured
    case disconnectStuck
    case repairFailed(String)

    var errorDescription: String? {
        switch self {
        case .openconnectNotFound: return "未找到 openconnect，请先 brew install openconnect"
        case .invalidProtocol: return "不支持的协议"
        case .connectFailed(let s): return "连接失败：\(s)"
        case .sudoNotConfigured: return "sudo 免密未配置或规则不完整，请重新点击\"一键配置\""
        case .disconnectStuck: return "断开超时，路由可能未回收 — 点\"修复路由\""
        case .repairFailed(let s): return "修复失败：\(s)"
        }
    }
}

enum OpenConnectRunner {
    static let pidPath = "/tmp/xdvpn.pid"
    static let logPath = "/tmp/xdvpn.log"

    /// 两个 root-owned helper。安装时 SudoersInstaller 把它们写进 /usr/local/libexec/，
    /// 用户无写权限 → 加进 sudoers NOPASSWD 白名单安全。
    static let stopHelperPath = "/usr/local/libexec/xdvpn-stop"
    static let repairHelperPath = "/usr/local/libexec/xdvpn-repair"

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

        // 抓一份连接前的默认网关快照，写到 /tmp/xdvpn-saved-gw。
        // xdvpn-repair 需要这个文件在 vpnc-script 状态丢失时恢复路由。
        _ = RouteSnapshot.captureCurrentGateway()

        try? FileManager.default.removeItem(atPath: pidPath)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        // 重要：不用 --setuid。openconnect 必须保持 root，否则收到 SIGTERM 时
        // 没权限跑 vpnc-script 回收路由，默认路由会留在已消失的 utun 上 → 全局断网。
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

    /// 通过 root-owned helper 发 SIGTERM，等 vpnc-script 清理路由。
    /// 15 秒不退就抛 disconnectStuck —— 调用方应该接着走 repair() 兜底。
    /// 绝不 SIGKILL：那会跳过 vpnc-script，路由残留。
    static func disconnect() throws {
        guard let pid = currentPid() else {
            // 没 pid 文件就没东西可断 —— 连带清理 gw 快照（不阻塞）
            RouteSnapshot.clear()
            return
        }

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

        for _ in 0..<150 {
            if !isAlive(pid) { break }
            usleep(100_000)
        }
        if isAlive(pid) {
            throw VPNError.disconnectStuck
        }
        try? FileManager.default.removeItem(atPath: pidPath)
        RouteSnapshot.clear()
    }

    /// 兜底修复：openconnect 死了/卡了/合盖后路由被毒、vpnc-script 状态丢 ——
    /// xdvpn-repair 会强杀 openconnect、删 utun 默认路由、按快照恢复原网关、
    /// 最后兜底 Wi-Fi 断电重连一次（Tunnelblick 的路数）。
    static func repair() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        proc.arguments = ["-n", repairHelperPath]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            throw VPNError.repairFailed(error.localizedDescription)
        }
        if proc.terminationStatus != 0 {
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            let msg =
                String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "exit \(proc.terminationStatus)"
            throw VPNError.repairFailed(msg.isEmpty ? "exit \(proc.terminationStatus)" : msg)
        }
        try? FileManager.default.removeItem(atPath: pidPath)
        RouteSnapshot.clear()
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
