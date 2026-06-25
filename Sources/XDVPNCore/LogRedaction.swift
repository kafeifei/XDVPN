import Foundation

/// 把 `line` 中出现的任何非空 secret 子串全部替换成 `***`。
///
/// 设计要点（脱敏是密码不泄漏的兜底，必须保守且确定）：
/// - 空串 secret 忽略：否则 `replacingOccurrences(of: "")` 会在每个字符间隙插 `***`。
/// - 按长度降序替换：避免短 secret 是长 secret 子串时先把长的拆碎导致漏抹。
///   例如 secrets=["pass","password123"]，先替换 "password123" 整体为 ***，
///   再替换 "pass" 时已无匹配，结果干净。
/// - 全部出现位置都替换（`replacingOccurrences` 默认替换所有匹配）。
/// - 纯函数、无副作用，可在 XDVPNCore 单测。
public func redactSecrets(_ line: String, secrets: [String]) -> String {
    let nonEmpty = secrets.filter { !$0.isEmpty }
    guard !nonEmpty.isEmpty else { return line }
    // 长度降序，长的先替换
    let ordered = nonEmpty.sorted { $0.count > $1.count }
    var result = line
    for secret in ordered {
        result = result.replacingOccurrences(of: secret, with: "***")
    }
    return result
}
