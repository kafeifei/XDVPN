import Foundation
import OSLog
import XDVPNCore

// MARK: - 日志级别

enum LogLevel: String {
    case info
    case warn
    case error

    /// 面板里的中文短标签
    var label: String {
        switch self {
        case .info:  return "信息"
        case .warn:  return "警告"
        case .error: return "错误"
        }
    }
}

// MARK: - 单条日志

struct LogEntry: Identifiable {
    let id = UUID()
    let time: Date
    let level: LogLevel
    let message: String
}

// MARK: - 应用内运行日志存储
//
// 环形缓冲：上限 500 条，超出丢最旧。所有 message 进入前先跑 redactSecrets 兜底脱敏，
// 同时镜像到 os_log（subsystem com.kafeifei.xdvpn / category runtime），方便 Console.app 查。
// secrets 来源由 VPNController 注入闭包（返回当前内存里的密码），双保险：
// 即便某条 message 不慎拼进了密码，也会在这里被抹成 ***。
@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()

    private static let maxEntries = 500

    @Published private(set) var entries: [LogEntry] = []

    /// 由 VPNController 设置：返回当前需要脱敏的字符串（如内存密码）。
    /// 默认空，保证在 controller 还没初始化时也不崩。
    var secretsProvider: @MainActor () -> [String] = { [] }

    private let osLogger = Logger(subsystem: "com.kafeifei.xdvpn", category: "runtime")

    private init() {}

    func log(_ level: LogLevel, _ message: String) {
        let safe = redactSecrets(message, secrets: secretsProvider())
        let entry = LogEntry(time: Date(), level: level, message: safe)
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        // 镜像到 os_log（脱敏后的内容；标成 .public 才能在 Console 看到全文，
        // 内容已脱敏故安全）
        switch level {
        case .info:  osLogger.info("\(safe, privacy: .public)")
        case .warn:  osLogger.warning("\(safe, privacy: .public)")
        case .error: osLogger.error("\(safe, privacy: .public)")
        }
    }

    func clear() {
        entries.removeAll()
    }

    /// 纯文本导出（复制全部用）。每行 `HH:mm:ss 级别 message`。
    func plainText() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return entries.map { e in
            "\(fmt.string(from: e.time)) \(e.level.label) \(e.message)"
        }.joined(separator: "\n")
    }
}

// MARK: - 全局便捷函数
//
// 必须在 MainActor 上调用。非 MainActor 调用点请包 `Task { @MainActor in appLog(...) }`。
@MainActor
func appLog(_ level: LogLevel = .info, _ message: String) {
    LogStore.shared.log(level, message)
}
