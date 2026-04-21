import Foundation

/// 连接前把原始默认网关存下来，方便"xdvpn-repair"在 openconnect 崩溃、
/// vpnc-script 的 /var/run/vpnc/defaultroute.* 丢失时，手动把路由拉回来。
///
/// 路径选 /tmp/xdvpn-saved-gw：App 以用户身份写，repair 以 root 身份读；
/// mode 0644 让 root 可读，/tmp 被清也无所谓（下次连接会重写）。
enum RouteSnapshot {
    static let path = "/tmp/xdvpn-saved-gw"

    /// 解析 `route -n get default` 拿当前默认网关 IPv4，成功则写入快照。
    /// 在"连接前"调用。已在 VPN 状态下调用会拿到 VPN 的网关，别错时机。
    @discardableResult
    static func captureCurrentGateway() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/sbin/route")
        proc.arguments = ["-n", "get", "default"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        // 找 "gateway: 192.168.0.1" 和 "interface: en0"
        var gw: String?
        var iface: String?
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let range = trimmed.range(of: "gateway:") {
                gw = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
            } else if let range = trimmed.range(of: "interface:") {
                iface = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
            }
        }
        // 若当前默认路由已在 VPN 上（utun*），说明调用时机错了 —— 拒绝保存，
        // 否则下次"修复"会把网关指向 VPN 对端 IP，反而把用户锁死
        guard let gw, !gw.isEmpty,
              !(iface?.hasPrefix("utun") ?? false)
        else { return nil }

        // 写入快照文件（忽略错误，有快照是 bonus，没也不阻断连接）
        try? (gw + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        // 确保 root 可读
        _ = try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: path
        )
        return gw
    }

    static var savedGateway: String? {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func clear() {
        try? FileManager.default.removeItem(atPath: path)
    }
}
