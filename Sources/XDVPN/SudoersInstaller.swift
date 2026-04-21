import Foundation

enum SudoersInstaller {
    static let sudoersPath = "/etc/sudoers.d/xdvpn"
    static let helperPath = OpenConnectRunner.stopHelperPath  // /usr/local/libexec/xdvpn-stop
    static let helperDir = "/usr/local/libexec"

    /// 两个文件都存在且 helper 内容校验通过才算已安装。
    static var isInstalled: Bool {
        guard FileManager.default.fileExists(atPath: sudoersPath) else { return false }
        guard FileManager.default.fileExists(atPath: helperPath) else { return false }
        // 检查 helper 文件第一行是否为我们的 shebang（防止被篡改/版本不匹配）
        if let data = try? Data(contentsOf: URL(fileURLWithPath: helperPath)),
           let content = String(data: data, encoding: .utf8),
           content.hasPrefix("#!/bin/bash\n# xdvpn-stop")
        {
            return true
        }
        return false
    }

    /// helper 脚本内容：只做一件事 — SIGTERM openconnect（pid 来自固定路径）。
    /// 不接受任何参数，行为完全固定；把它放到 sudoers NOPASSWD 白名单里很安全。
    private static let helperScript = #"""
    #!/bin/bash
    # xdvpn-stop — 由 XDVPN App 安装，root 所有，用户不可写。
    # 功能固定：读 /tmp/xdvpn.pid → SIGTERM → 等待 openconnect 执行 vpnc-script
    # 回收路由后自行退出。不做 SIGKILL，避免路由残留。

    set -u
    PID_FILE="/tmp/xdvpn.pid"
    if [ ! -f "$PID_FILE" ]; then exit 0; fi
    PID="$(cat "$PID_FILE" 2>/dev/null)"
    if [ -z "$PID" ]; then exit 0; fi

    # 仅当目标进程是 openconnect 时才发信号（防御性）
    COMM="$(ps -o comm= -p "$PID" 2>/dev/null || true)"
    case "$COMM" in
        *openconnect*) ;;
        *) exit 0 ;;
    esac

    kill -TERM "$PID" 2>/dev/null || exit 0

    # 等最多 12 秒让 vpnc-script 回收路由
    for _ in $(seq 1 60); do
        if ! kill -0 "$PID" 2>/dev/null; then
            rm -f "$PID_FILE"
            exit 0
        fi
        sleep 0.2
    done

    # 超时：不强杀，让调用方知道路由可能没干净
    exit 2
    """#

    static func install() throws {
        guard let ocPath = OpenConnectRunner.openconnectPath else {
            throw VPNError.openconnectNotFound
        }
        let user = NSUserName()
        let sudoersRule = """
        \(user) ALL=(root) NOPASSWD: \(ocPath)
        \(user) ALL=(root) NOPASSWD: \(helperPath)
        """

        // 一个 shell 脚本原子化完成所有写入；任一步失败整体失败，不会只装一半。
        let shell = """
        set -eu

        # 1) 写 helper 脚本到固定路径，root:wheel 0755
        mkdir -p '\(helperDir)'
        HELPER_TMP=$(mktemp)
        cat > "$HELPER_TMP" <<'XDVPN_HELPER_EOF'
        \(helperScript)
        XDVPN_HELPER_EOF
        chown root:wheel "$HELPER_TMP"
        chmod 0755 "$HELPER_TMP"
        mv "$HELPER_TMP" '\(helperPath)'

        # 2) 写 sudoers 规则，visudo -c 严格校验通过才落盘
        SUDOERS_TMP=$(mktemp)
        cat > "$SUDOERS_TMP" <<'XDVPN_SUDOERS_EOF'
        \(sudoersRule)
        XDVPN_SUDOERS_EOF
        chown root:wheel "$SUDOERS_TMP"
        chmod 0440 "$SUDOERS_TMP"
        /usr/sbin/visudo -c -f "$SUDOERS_TMP" >/dev/null
        mv "$SUDOERS_TMP" '\(sudoersPath)'
        """

        let script = "do shell script \(appleScriptQuote(shell)) with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err {
            let msg = err[NSAppleScript.errorMessage] as? String ?? "未知错误"
            throw NSError(
                domain: "XDVPN", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "写入 sudoers/helper 失败：\(msg)"]
            )
        }
    }

    static func uninstall() throws {
        let shell = "rm -f '\(sudoersPath)' '\(helperPath)'"
        let script = "do shell script \(appleScriptQuote(shell)) with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err {
            let msg = err[NSAppleScript.errorMessage] as? String ?? "未知错误"
            throw NSError(
                domain: "XDVPN", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "卸载失败：\(msg)"]
            )
        }
    }

    private static func appleScriptQuote(_ s: String) -> String {
        let escaped =
            s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }
}
