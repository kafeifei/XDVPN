import Foundation
import LocalAuthentication

enum BiometricGate {
    private static let key = "xdvpn.lastAuth"
    private static let ttl: TimeInterval = 7 * 86400

    static var needsAuth: Bool {
        let last = UserDefaults.standard.double(forKey: key)
        return Date().timeIntervalSince1970 - last >= ttl
    }

    static func ensure() async throws {
        guard needsAuth else { return }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "输入密码"
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw error ?? NSError(domain: "XDVPN", code: 10,
                userInfo: [NSLocalizedDescriptionKey: "生物识别不可用"])
        }
        let ok = try await ctx.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "解锁 XDVPN 连接权限"
        )
        if !ok { throw NSError(domain: "XDVPN", code: 11,
            userInfo: [NSLocalizedDescriptionKey: "Touch ID 未通过"]) }
        markActivity()
    }

    /// 连接成功就调一次，刷新"最后一次成功活动"时间戳，
    /// 让 7 天窗口从本次成功算起滚动。
    static func markActivity() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
    }
}
