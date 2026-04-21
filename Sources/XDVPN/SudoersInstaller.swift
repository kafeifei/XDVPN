import Foundation

enum SudoersInstaller {
    static let sudoersPath = "/etc/sudoers.d/xdvpn"
    static let stopHelperPath = OpenConnectRunner.stopHelperPath      // /usr/local/libexec/xdvpn-stop
    static let repairHelperPath = OpenConnectRunner.repairHelperPath  // /usr/local/libexec/xdvpn-repair
    static let helperDir = "/usr/local/libexec"

    /// 四件套都对才算已安装：
    /// - sudoers 文件存在
    /// - 两个 helper 文件都存在且 shebang 头匹配（防篡改/版本错配）
    static var isInstalled: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sudoersPath),
              fm.fileExists(atPath: stopHelperPath),
              fm.fileExists(atPath: repairHelperPath) else { return false }
        return helperHasSignature(stopHelperPath, signature: "#!/bin/bash\n# xdvpn-stop")
            && helperHasSignature(repairHelperPath, signature: "#!/bin/bash\n# xdvpn-repair")
    }

    private static func helperHasSignature(_ path: String, signature: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let content = String(data: data, encoding: .utf8) else { return false }
        return content.hasPrefix(signature)
    }

    /// 读 /tmp/xdvpn.pid → SIGTERM openconnect → 等 vpnc-script 回收路由。
    /// 不 SIGKILL —— 超时留给上层 repair 去兜。固定行为、不收参数 = NOPASSWD 白名单安全。
    private static let stopHelperScript = #"""
    #!/bin/bash
    # xdvpn-stop — 由 XDVPN 安装，root:wheel 0755，用户不可写。
    # 功能固定：读 /tmp/xdvpn.pid → SIGTERM → 等 openconnect 回收路由后退出。

    set -u
    PID_FILE="/tmp/xdvpn.pid"
    if [ ! -f "$PID_FILE" ]; then exit 0; fi
    PID="$(cat "$PID_FILE" 2>/dev/null)"
    if [ -z "$PID" ]; then exit 0; fi

    # 仅当目标是 openconnect 才发信号（防御）
    COMM="$(ps -o comm= -p "$PID" 2>/dev/null || true)"
    case "$COMM" in
        *openconnect*) ;;
        *) exit 0 ;;
    esac

    kill -TERM "$PID" 2>/dev/null || exit 0

    # 最多等 12s 让 vpnc-script 跑完
    for _ in $(seq 1 60); do
        if ! kill -0 "$PID" 2>/dev/null; then
            rm -f "$PID_FILE"
            exit 0
        fi
        sleep 0.2
    done

    # 超时：不强杀，留给 xdvpn-repair 兜底
    exit 2
    """#

    /// 修复路由残局：openconnect 崩/卡、vpnc-script 没执行、合盖换网后路由毒化 ——
    /// 强杀 → 删 utun 默认路由 → 按快照恢复原网关 → 兜底 Wi-Fi 断电重连。
    /// 行为固定，唯一输入是 /tmp/xdvpn-saved-gw（用户可写，但只能写一个 IP 字符串，
    /// 最坏结果是"默认路由设错 IP" —— 不会升权）。
    private static let repairHelperScript = #"""
    #!/bin/bash
    # xdvpn-repair — 由 XDVPN 安装，root:wheel 0755，用户不可写。
    # 触发时机：openconnect 崩溃/卡死、合盖换网导致默认路由残留在 utun。

    set -u

    # 1) 强制杀 openconnect（xdvpn-stop 可能已经 SIGTERM 过，这里兜底 SIGKILL）
    killall -TERM openconnect 2>/dev/null || true
    sleep 1
    killall -KILL openconnect 2>/dev/null || true

    # 2) 若当前默认路由还走 utun，把它删掉
    DEFAULT_IF="$(/sbin/route -n get default 2>/dev/null | awk -F': ' '/interface:/ {gsub(/ /,"",$2); print $2}')"
    if [[ "$DEFAULT_IF" == utun* ]]; then
        /sbin/route delete default 2>/dev/null || true
    fi

    # 3) 按连接前保存的原网关恢复默认路由
    SAVED="/tmp/xdvpn-saved-gw"
    if [[ -s "$SAVED" ]]; then
        GW="$(tr -d ' \t\r\n' < "$SAVED")"
        if [[ -n "$GW" ]]; then
            CUR_GW="$(/sbin/route -n get default 2>/dev/null | awk -F': ' '/gateway:/ {gsub(/ /,"",$2); print $2}')"
            if [[ "$CUR_GW" != "$GW" ]]; then
                /sbin/route -n add default "$GW" 2>/dev/null \
                    || /sbin/route -n change default "$GW" 2>/dev/null \
                    || true
            fi
        fi
    fi

    # 4) 兜底：如果默认路由仍缺失或仍在 utun —— Wi-Fi 断电重连（Tunnelblick 的招）
    DEFAULT_IF="$(/sbin/route -n get default 2>/dev/null | awk -F': ' '/interface:/ {gsub(/ /,"",$2); print $2}')"
    if [[ -z "$DEFAULT_IF" || "$DEFAULT_IF" == utun* ]]; then
        WIFI_DEV="$(/usr/sbin/networksetup -listallhardwareports | awk '/Hardware Port: Wi-Fi/{getline; print $2}')"
        if [[ -n "$WIFI_DEV" ]]; then
            /usr/sbin/networksetup -setairportpower "$WIFI_DEV" off 2>/dev/null || true
            sleep 2
            /usr/sbin/networksetup -setairportpower "$WIFI_DEV" on  2>/dev/null || true
        fi
    fi

    # 5) 清状态文件
    rm -f /tmp/xdvpn.pid /tmp/xdvpn-saved-gw

    exit 0
    """#

    static func install() throws {
        guard let ocPath = OpenConnectRunner.openconnectPath else {
            throw VPNError.openconnectNotFound
        }
        let user = NSUserName()
        // 三条 NOPASSWD：openconnect 本体 + stop helper + repair helper。
        // 全都是固定路径，加起来不比 passwordless sudo 一个命令更危险（helper 都 root-owned）。
        let sudoersRule = """
        \(user) ALL=(root) NOPASSWD: \(ocPath)
        \(user) ALL=(root) NOPASSWD: \(stopHelperPath)
        \(user) ALL=(root) NOPASSWD: \(repairHelperPath)
        """

        let shell = """
        set -eu

        mkdir -p '\(helperDir)'

        # 1) 写 xdvpn-stop
        STOP_TMP=$(mktemp)
        cat > "$STOP_TMP" <<'XDVPN_STOP_EOF'
        \(stopHelperScript)
        XDVPN_STOP_EOF
        chown root:wheel "$STOP_TMP"
        chmod 0755 "$STOP_TMP"
        mv "$STOP_TMP" '\(stopHelperPath)'

        # 2) 写 xdvpn-repair
        REPAIR_TMP=$(mktemp)
        cat > "$REPAIR_TMP" <<'XDVPN_REPAIR_EOF'
        \(repairHelperScript)
        XDVPN_REPAIR_EOF
        chown root:wheel "$REPAIR_TMP"
        chmod 0755 "$REPAIR_TMP"
        mv "$REPAIR_TMP" '\(repairHelperPath)'

        # 3) 写 sudoers（visudo -c 严格校验再落盘）
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
        let shell = "rm -f '\(sudoersPath)' '\(stopHelperPath)' '\(repairHelperPath)'"
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
