import Foundation

/// 服务器登录页带「组」下拉框、而 openconnect 又没法替用户选时，它的输出里带着全部可选项：
///
///     GROUP: [Default-Group|Staff VPN|Contractors]:
///     User input required in non-interactive mode
///
/// 填了不存在的组时前面还会多一行 `Auth choice "X" not available`。
/// 认证组在界面上是手填的，所以把这段输出换成一句能照着填的话；认不出来就返回 nil，
/// 调用方照旧显示 openconnect 的原始输出。
public func authGroupHint(fromOpenConnectOutput output: String) -> String? {
    for line in output.split(whereSeparator: \.isNewline) {
        guard let open = line.firstIndex(of: "["),
              let close = line[open...].range(of: "]:")?.lowerBound else { continue }
        let choices = line[line.index(after: open)..<close]
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard choices.count >= 2 else { continue }

        let list = choices.joined(separator: "、")
        if output.contains("Auth choice \"") {
            return "认证组填写有误。服务器上可选的认证组：\(list)"
        }
        return "服务器要求选择认证组。请在「认证组」里填写其中一个：\(list)"
    }
    return nil
}
