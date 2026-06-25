import Foundation

/// 由一组接口名算出「物理出口指纹」：滤掉 utun*（VPN 自己的虚拟接口），排序去序后拼接。
/// 指纹变化 = 物理出口集合变了 = 换网 / 漫游到不同接口 / 插拔网线。
public func physicalInterfaceFingerprint(_ names: [String]) -> String {
    names.filter { !$0.hasPrefix("utun") }.sorted().joined(separator: ",")
}

/// 换网检测器（纯逻辑、可单测）。规则：
/// - 首个非空指纹只记基线、不触发（避免启动/首帧误判）
/// - 空指纹（暂时无网）不触发也不更新基线（等网回来再比，避免把"断网→同网回来"当换网）
/// - 之后与上一个非空指纹不同才触发
public struct NetworkChangeDetector: Sendable {
    private var last: String?
    public init() {}

    public mutating func observe(fingerprint: String) -> Bool {
        if fingerprint.isEmpty { return false }       // 无网：不触发、不动基线
        guard let prev = last else {
            last = fingerprint                        // 首个非空指纹只记基线
            return false
        }
        last = fingerprint
        return fingerprint != prev
    }
}
