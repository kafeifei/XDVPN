import Foundation

/// 一次性把免密 sudo + 两个 root helper 装进系统。
/// helper 是固定行为、root 所有、用户不可写，所以放进 sudoers NOPASSWD 白名单是安全的。
enum SudoersInstaller {
    /// 每次改 helper 脚本内容后递增。isInstalled 会校验磁盘上的版本号，
    /// 不匹配 → sudoConfigured=false → UI 自动提示"一键配置"覆盖升级。
    static let helperVersion = 4

    static let sudoersPath = "/etc/sudoers.d/xdvpn"
    static let helperDir = "/usr/local/libexec"

    /// 被 openconnect 以 root 身份通过 --script=<path> 调用。
    /// 不需要单独的 sudoers 条目（调用链：user sudo openconnect → root openconnect → root script）。
    static let routeScriptPath = "\(helperDir)/xdvpn-route-script"

    /// 用户 sudo 直接调，做上次会话的清理。
    /// 走 sudoers NOPASSWD。
    static let cleanupPath = "\(helperDir)/xdvpn-cleanup"
    static let dnsProxyPath = "\(helperDir)/xdvpn-dns-proxy"

    /// v0.2 的 helper，v0.3 安装时顺手删掉（用户从 0.2 升级时的清理）
    private static let legacyPaths = [
        "\(helperDir)/xdvpn-stop",
        "\(helperDir)/xdvpn-repair",
        "/tmp/xdvpn-saved-gw",
        "/tmp/xdvpn.log",
    ]

    // MARK: - 安装状态

    /// 三个条件全满足才算已安装：
    /// - sudoers 文件存在
    /// - 两个 helper 文件都存在
    /// - helper 的版本号 == helperVersion（脚本内容更新后自动触发重装）
    static var isInstalled: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sudoersPath),
              fm.fileExists(atPath: routeScriptPath),
              fm.fileExists(atPath: cleanupPath),
              fm.fileExists(atPath: dnsProxyPath) else { return false }
        let ver = "v\(helperVersion)"
        return helperHasSignature(routeScriptPath, signature: "#!/bin/bash\n# xdvpn-route-script \(ver)")
            && helperHasSignature(cleanupPath, signature: "#!/bin/bash\n# xdvpn-cleanup \(ver)")
    }

    private static func helperHasSignature(_ path: String, signature: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let content = String(data: data, encoding: .utf8) else { return false }
        return content.hasPrefix(signature)
    }

    // MARK: - Helper 脚本内容

    /// openconnect 的 --script 替代品。
    /// reason=connect 时：配 utun、加 def1 路由、加 VPN 网关 host route、插 DNS，
    /// 并把每一条"加了什么"append 到 /tmp/xdvpn.session（write-ahead）。
    /// reason=disconnect 时：读 session，逐项 remove。
    /// 原则：只做加法 + 删自己加的；从不碰系统原有的 default route / DNS / 其他接口。
    private static let routeScriptContent = #"""
    #!/bin/bash
    # xdvpn-route-script v\#(helperVersion) — 由 XDVPN 安装。root:wheel 0755，用户不可写。
    # 被 openconnect --script 调用，替代 vpnc-script。
    # 设计原则：只做加法。永远不 touch 系统原有的 default route。
    set -u

    SESSION="/tmp/xdvpn.session"

    append_state() { echo "$1" >> "$SESSION"; }

    case "${reason:-}" in
      connect)
        # 1) utun 基本配置（点对点，netmask /32）
        ifconfig "$TUNDEV" inet "$INTERNAL_IP4_ADDRESS" "$INTERNAL_IP4_ADDRESS" \
            netmask 255.255.255.255 \
            mtu "${INTERNAL_IP4_MTU:-1300}" up

        # 2) 新 session 文件（write-ahead：先记录意图，再执行）
        echo "# xdvpn session $(date -u +%FT%TZ)" > "$SESSION"
        append_state "TUNDEV=$TUNDEV"
        append_state "VPNGATEWAY=$VPNGATEWAY"

        # 3) VPN 服务器自身的 host route：保证去 VPN server 的 TCP/DTLS 包走物理网卡
        #    不然它会被我们加的 /1 路由吸进 utun，环路
        #    注意：必须从物理网卡（en*）取网关，不能用 route -n get default ——
        #    openconnect 调脚本前可能已在 utun 上建了 default，会取到 VPN 内部网关
        ORIG_GW="$(netstat -rn 2>/dev/null | awk '/^default[[:space:]].*[[:space:]]en[0-9]/{print $2; exit}')"
        if [ -n "$ORIG_GW" ]; then
            if route add -host "$VPNGATEWAY" "$ORIG_GW" 2>/dev/null; then
                append_state "ROUTE_HOST=$VPNGATEWAY"
            fi
        fi

        # 4) 劫持流量：三档决策
        #    a) 客户端分流（XDVPN 写的 split conf 文件存在）→ 走 conf 里的 CIDR
        #       若同时有 CISCO_SPLIT_INC，合并（客户端 ∪ 服务器）
        #    b) 仅服务器 split（只有 CISCO_SPLIT_INC）→ 走服务器推送
        #    c) 都没有 → def1 全流量（两条 /1）
        SPLIT_CONF="/tmp/xdvpn-split.conf"
        DOMAIN_CONF="/tmp/xdvpn-split-domains.conf"
        if [ -f "$SPLIT_CONF" ] || [ -f "$DOMAIN_CONF" ] || [ -n "${CISCO_SPLIT_INC:-}" ]; then
            # split tunnel —— 用户明确选择，不 fallback 到 def1
            if [ -f "$SPLIT_CONF" ]; then
                while IFS= read -r cidr || [ -n "$cidr" ]; do
                    case "$cidr" in ""|"#"*) continue ;; esac
                    if route add -net "$cidr" -interface "$TUNDEV" 2>/dev/null; then
                        append_state "ROUTE_NET=$cidr"
                    fi
                done < "$SPLIT_CONF"
            fi
            if [ -n "${CISCO_SPLIT_INC:-}" ]; then
                i=0
                while true; do
                    eval "addr=\${CISCO_SPLIT_INC_${i}_ADDR:-}"
                    eval "masklen=\${CISCO_SPLIT_INC_${i}_MASKLEN:-}"
                    [ -z "$addr" ] && break
                    # route add 重复会失败（2>/dev/null 吃掉），自然去重
                    if route add -net "$addr/$masklen" -interface "$TUNDEV" 2>/dev/null; then
                        append_state "ROUTE_NET=$addr/$masklen"
                    fi
                    i=$((i + 1))
                done
            fi
        else
            # full tunnel — 两条 /1 覆盖 default，不删不改原 default
            if route add -net 0.0.0.0/1 -interface "$TUNDEV" 2>/dev/null; then
                append_state "ROUTE_NET=0.0.0.0/1"
            fi
            if route add -net 128.0.0.0/1 -interface "$TUNDEV" 2>/dev/null; then
                append_state "ROUTE_NET=128.0.0.0/1"
            fi
        fi

        # 5) DNS
        if [ -f "$DOMAIN_CONF" ] && [ -n "${INTERNAL_IP4_DNS:-}" ]; then
            # 域名分流：fork dns-proxy，不做全局 DNS 注入
            VPN_DNS=$(echo "$INTERNAL_IP4_DNS" | awk '{print $1}')
            DNS_PROXY="/usr/local/libexec/xdvpn-dns-proxy"
            if [ -x "$DNS_PROXY" ]; then
                nohup "$DNS_PROXY" --vpn-dns "$VPN_DNS" --utun "$TUNDEV" \
                    --domains "$DOMAIN_CONF" </dev/null >/dev/null 2>&1 &
                append_state "DNS_PROXY_PID=$!"
            fi
        elif [ -n "${INTERNAL_IP4_DNS:-}" ]; then
            # 原有全局 DNS 注入（无域名分流时）
            SCUTIL_KEY="State:/Network/Service/com.kafeifei.xdvpn/DNS"
            DNS_VALUES="*"
            for d in $INTERNAL_IP4_DNS; do
                DNS_VALUES="$DNS_VALUES $d"
            done
            DOMAIN="${CISCO_DEF_DOMAIN:-}"
            scutil <<SCUTIL_EOF
    d.init
    d.add ServerAddresses ${DNS_VALUES}
    d.add SupplementalMatchDomains * ""
    ${DOMAIN:+d.add SearchDomains * ${DOMAIN}}
    set ${SCUTIL_KEY}
    quit
    SCUTIL_EOF
            append_state "SCUTIL_KEY=$SCUTIL_KEY"
        fi
        ;;

      disconnect)
        # openconnect 正常退出时走这里。逐项 remove 我们加的东西。
        # xdvpn-cleanup 崩溃恢复时做同样的事（冗余是故意的）。
        if [ -f "$SESSION" ]; then
            # Kill dns-proxy
            while IFS='=' read -r tag val; do
                if [ "$tag" = "DNS_PROXY_PID" ]; then
                    kill -TERM "$val" 2>/dev/null || true
                    for _ in $(seq 1 10); do
                        kill -0 "$val" 2>/dev/null || break
                        sleep 0.1
                    done
                fi
            done < "$SESSION"
            # 兜底：清理可能残留的 resolver 文件
            grep -rl 'nameserver 127.0.0.1' /etc/resolver/ 2>/dev/null | xargs rm -f 2>/dev/null || true

            # DNS
            KEY=""
            while IFS='=' read -r tag val; do
                [ "$tag" = "SCUTIL_KEY" ] && KEY="$val"
            done < "$SESSION"
            if [ -n "$KEY" ]; then
                scutil <<SCUTIL_REM_EOF
    remove ${KEY}
    quit
    SCUTIL_REM_EOF
            fi

            # 读 TUNDEV 用来删路由
            TD=""
            while IFS='=' read -r tag val; do
                [ "$tag" = "TUNDEV" ] && TD="$val"
            done < "$SESSION"

            # 逐条路由 delete
            while IFS='=' read -r tag val; do
                case "$tag" in
                  ROUTE_HOST)
                    route delete -host "$val" 2>/dev/null || true ;;
                  ROUTE_NET)
                    [ -n "$TD" ] && route delete -net "$val" -interface "$TD" 2>/dev/null || true ;;
                esac
            done < "$SESSION"

            rm -f "$SESSION"
        fi
        # utun 接口会在 openconnect close fd 时被 kernel 自动销毁
        ;;

      *)
        # reason 为 reconnect / attempt-reconnect / pre-init 等 —— v0.3 暂不特殊处理
        ;;
    esac

    exit 0
    """#

    /// 启动 / 用户主动断开 / 合盖睡眠前调用。
    /// 幂等：每步失败跳过。永远不扩展到 session 以外的东西。
    private static let cleanupScriptContent = #"""
    #!/bin/bash
    # xdvpn-cleanup v\#(helperVersion) — 由 XDVPN 安装。root:wheel 0755。
    # 用户通过 sudoers NOPASSWD 调用。
    # 功能：按 /tmp/xdvpn.pid + /tmp/xdvpn.session 清掉我们自己上次加的所有东西。
    # 原则：只动自己的 pid、自己的 session 里列出的东西；其他一概不碰。
    set -u

    PID_FILE="/tmp/xdvpn.pid"
    SESSION="/tmp/xdvpn.session"

    # 1) 停 openconnect（按 pid 精确杀，不 killall）
    if [ -s "$PID_FILE" ]; then
        PID="$(cat "$PID_FILE" 2>/dev/null | tr -d ' \t\r\n')"
        if [ -n "$PID" ]; then
            # 校验是不是 openconnect（pid 可能被复用给了别的进程）
            COMM="$(ps -o comm= -p "$PID" 2>/dev/null || true)"
            if echo "$COMM" | grep -q openconnect; then
                # SIGTERM 让 openconnect 走 --script=disconnect 路径清干净
                kill -TERM "$PID" 2>/dev/null || true
                # 最多等 12s
                for _ in $(seq 1 60); do
                    kill -0 "$PID" 2>/dev/null || break
                    sleep 0.2
                done
                # 还没死就 SIGKILL（是我们自己启动的进程，有权杀）
                kill -KILL "$PID" 2>/dev/null || true
            fi
        fi
        rm -f "$PID_FILE"
    fi

    # 停 dns-proxy（从 session 读 PID）
    if [ -f "$SESSION" ]; then
        while IFS='=' read -r tag val; do
            if [ "$tag" = "DNS_PROXY_PID" ]; then
                kill -TERM "$val" 2>/dev/null || true
                for _ in $(seq 1 10); do
                    kill -0 "$val" 2>/dev/null || break
                    sleep 0.1
                done
                kill -KILL "$val" 2>/dev/null || true
            fi
        done < "$SESSION"
    fi

    # openconnect 退出 → kernel close tun fd → utun 销毁 → interface-scoped 路由自动跟着清掉

    # 2) 如果 disconnect script 没跑完（openconnect 被 SIGKILL / crash），手动清残留
    if [ -f "$SESSION" ]; then
        # DNS（这个不是 interface-scoped，kernel 不会清）
        KEY=""
        while IFS='=' read -r tag val; do
            [ "$tag" = "SCUTIL_KEY" ] && KEY="$val"
        done < "$SESSION"
        if [ -n "$KEY" ]; then
            scutil <<EOF
    remove ${KEY}
    quit
    EOF
        fi

        # VPN 网关 host route（也不是 interface-scoped）
        while IFS='=' read -r tag val; do
            [ "$tag" = "ROUTE_HOST" ] && route delete -host "$val" 2>/dev/null || true
        done < "$SESSION"

        # 防御性：/1 和 split 路由理论上已跟 utun 一起没了，再删一遍无害
        TD=""
        while IFS='=' read -r tag val; do
            [ "$tag" = "TUNDEV" ] && TD="$val"
        done < "$SESSION"
        if [ -n "$TD" ]; then
            while IFS='=' read -r tag val; do
                [ "$tag" = "ROUTE_NET" ] && route delete -net "$val" -interface "$TD" 2>/dev/null || true
            done < "$SESSION"
            # 兜底：极罕见情况 utun 没被 kernel 清，我们自己 destroy
            ifconfig "$TD" destroy 2>/dev/null || true
        fi

        rm -f "$SESSION"
    fi

    # 3) 清掉分流配置文件（下次连接会由 XDVPN 按当前 UI 状态重新写）
    # 兜底：清理可能残留的 resolver 文件
    grep -rl 'nameserver 127.0.0.1' /etc/resolver/ 2>/dev/null | xargs rm -f 2>/dev/null || true
    rm -f "/tmp/xdvpn-split.conf" "/tmp/xdvpn-split-domains.conf"

    exit 0
    """#

    // MARK: - 安装 / 卸载

    /// 写两个 helper + sudoers。整个过程用一个 AppleScript do shell script with
    /// administrator privileges 完成，用户只弹一次管理员授权。
    /// 任何一步失败 set -e 整体失败，不会只装一半。
    static func install() throws {
        guard let ocPath = OpenConnectRunner.openconnectPath else {
            throw VPNError.openconnectNotFound
        }
        let user = NSUserName()
        // 2 条 NOPASSWD：openconnect + cleanup。
        // route-script 由 openconnect 调用，user 不直接 sudo 它，不需要条目。
        let sudoersRule = """
        \(user) ALL=(root) NOPASSWD: \(ocPath)
        \(user) ALL=(root) NOPASSWD: \(cleanupPath)
        """

        let bundleBinDir = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS").path
        let proxySourcePath = bundleBinDir + "/xdvpn-dns-proxy"

        let shell = """
        set -eu

        mkdir -p '\(helperDir)'

        # 清 v0.2 旧文件（升级路径）
        rm -f \(legacyPaths.map { "'\($0)'" }.joined(separator: " "))

        # 1) xdvpn-route-script
        RS_TMP=$(mktemp)
        cat > "$RS_TMP" <<'XDVPN_ROUTESCRIPT_EOF'
        \(routeScriptContent)
        XDVPN_ROUTESCRIPT_EOF
        chown root:wheel "$RS_TMP"
        chmod 0755 "$RS_TMP"
        mv "$RS_TMP" '\(routeScriptPath)'

        # 2) xdvpn-cleanup
        CL_TMP=$(mktemp)
        cat > "$CL_TMP" <<'XDVPN_CLEANUP_EOF'
        \(cleanupScriptContent)
        XDVPN_CLEANUP_EOF
        chown root:wheel "$CL_TMP"
        chmod 0755 "$CL_TMP"
        mv "$CL_TMP" '\(cleanupPath)'

        # 3) xdvpn-dns-proxy（编译好的二进制，从 app bundle 复制）
        cp '\(proxySourcePath)' '\(dnsProxyPath)'
        chown root:wheel '\(dnsProxyPath)'
        chmod 0755 '\(dnsProxyPath)'

        # 4) sudoers（visudo -c 严格校验通过才落盘）
        SU_TMP=$(mktemp)
        cat > "$SU_TMP" <<'XDVPN_SUDOERS_EOF'
        \(sudoersRule)
        XDVPN_SUDOERS_EOF
        chown root:wheel "$SU_TMP"
        chmod 0440 "$SU_TMP"
        /usr/sbin/visudo -c -f "$SU_TMP" >/dev/null
        mv "$SU_TMP" '\(sudoersPath)'
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
        let paths = [sudoersPath, routeScriptPath, cleanupPath, dnsProxyPath] + legacyPaths
        let shell = "rm -f " + paths.map { "'\($0)'" }.joined(separator: " ")
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
